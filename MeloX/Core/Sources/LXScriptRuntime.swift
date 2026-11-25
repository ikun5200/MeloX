import CryptoKit
import Foundation
import JavaScriptCore
import Security

nonisolated struct LXScriptInfo: Sendable {
    let name: String
    let description: String
    let version: String
    let author: String
    let homepage: String
    let rawScript: String

    static let empty = LXScriptInfo(
        name: "未命名音源",
        description: "",
        version: "",
        author: "",
        homepage: "",
        rawScript: ""
    )

    var jsonString: String {
        let payload: [String: Any] = [
            "name": name,
            "description": description,
            "version": version,
            "author": author,
            "homepage": homepage,
            "rawScript": rawScript,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func parse(_ script: String) -> LXScriptInfo {
        guard let start = script.range(of: "/*"),
              let end = script.range(
                of: "*/",
                range: start.upperBound..<script.endIndex
              ) else {
            return LXScriptInfo(
                name: "未命名音源",
                description: "",
                version: "",
                author: "",
                homepage: "",
                rawScript: script
            )
        }

        let header = String(script[start.upperBound..<end.lowerBound])
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(
                in: .whitespaces
            )
            guard trimmed.hasPrefix("*") else { continue }
            let content = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }
            let parts = content.dropFirst().split(
                separator: " ",
                maxSplits: 1
            )
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(
                in: .whitespaces
            )
            fields[key] = value
        }

        return LXScriptInfo(
            name: fields["name"] ?? "未命名音源",
            description: fields["description"] ?? "",
            version: fields["version"] ?? "",
            author: fields["author"] ?? "",
            homepage: fields["homepage"] ?? "",
            rawScript: script
        )
    }
}

nonisolated struct LXSourceCapability: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let actions: [String]
    let qualitys: [String]

    var supportsMusicURL: Bool {
        actions.contains("musicUrl")
    }
}

nonisolated struct LXScriptDescriptor: Sendable {
    let script: LXScriptInfo
    let sources: [LXSourceCapability]

    var qqSource: LXSourceCapability? {
        sources.first { $0.id == "tx" && $0.supportsMusicURL }
    }
}

nonisolated enum LXScriptError: LocalizedError, Sendable {
    case unavailable
    case initializationFailed(String)
    case initializationTimedOut
    case notInitialized
    case javaScript(String)
    case requestTimedOut
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "洛雪源运行时不可用。"
        case .initializationFailed(let message):
            "洛雪源初始化失败：\(message)"
        case .initializationTimedOut:
            "洛雪源初始化超时。"
        case .notInitialized:
            "洛雪源尚未初始化。"
        case .javaScript(let message):
            "洛雪源脚本错误：\(message)"
        case .requestTimedOut:
            "洛雪源解析播放地址超时。"
        case .invalidURL:
            "洛雪源返回了无效的播放地址。"
        case .invalidResponse:
            "洛雪源返回了无法解析的数据。"
        }
    }
}

/// 在 JavaScriptCore 里执行 LX Music 自定义源脚本。
///
/// `JSContext` 不是线程安全的，所有脚本求值与 JSValue 调用都固定在
/// 同一个串行队列上；URLSession 回调会重新派发回该队列。
nonisolated final class LXScriptRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeloX.LXScriptRuntime")
    private let session: URLSession
    private let preload: String

    private var context: JSContext?
    private var scriptInfo: LXScriptInfo?
    private var descriptor: LXScriptDescriptor?
    private var initContinuation: CheckedContinuation<LXScriptDescriptor, Error>?
    private var musicContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var httpTasks: [String: URLSessionDataTask] = [:]
    private var timerWorkItems: [String: DispatchWorkItem] = [:]
    private var updateAlert: [String: Any]?
    private var isShutdown = false

    init(preload: String, session: URLSession = .shared) {
        self.preload = preload
        self.session = session
    }

    static func loadDefaultPreload() throws -> String {
        let url = Bundle.main.url(
            forResource: "LXScriptPreload",
            withExtension: "js",
            subdirectory: "LX"
        ) ?? Bundle.main.url(
            forResource: "LXScriptPreload",
            withExtension: "js"
        )
        guard let url else { throw LXScriptError.unavailable }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func initialize(
        script: String,
        info: LXScriptInfo? = nil
    ) async throws -> LXScriptDescriptor {
        let parsedInfo = info ?? .parse(script)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.initContinuation == nil, !self.isShutdown else {
                    continuation.resume(
                        throwing: LXScriptError.initializationFailed(
                            "初始化正在进行或已关闭"
                        )
                    )
                    return
                }
                self.initContinuation = continuation
                self.scriptInfo = parsedInfo
                do {
                    let context = try self.makeContext()
                    self.context = context
                    context.setObject(
                        parsedInfo.jsonString,
                        forKeyedSubscript: "__lxScriptInfoJSON" as NSString
                    )
                    try self.evaluate(self.preload)
                    try self.evaluate(script)
                    self.armInitializationTimeout()
                } catch {
                    self.finishInitialization(.failure(error))
                }
            }
        }
    }

    func resolveMusicURL(
        musicInfo: [String: Any],
        quality: String,
        source: String = "tx",
        timeout: TimeInterval = 20
    ) async throws -> String {
        guard descriptor != nil, !isShutdown else {
            throw LXScriptError.notInitialized
        }
        let musicInfoJSON: String
        do {
            musicInfoJSON = try Self.jsonString(musicInfo)
        } catch {
            throw LXScriptError.invalidResponse
        }

        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.isShutdown, let context = self.context else {
                    continuation.resume(
                        throwing: LXScriptError.notInitialized
                    )
                    return
                }
                self.musicContinuations[requestID] = continuation
                context.exception = nil
                context.objectForKeyedSubscript("__lxRequestMusicUrl")?
                    .call(withArguments: [
                        requestID,
                        source,
                        quality,
                        musicInfoJSON,
                    ])
                if let exception = context.exception {
                    context.exception = nil
                    self.finishMusicRequest(
                        requestID,
                        error: exception.toString() ?? "javascript error",
                        result: ""
                    )
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let continuation = self.musicContinuations
                        .removeValue(forKey: requestID) else {
                        return
                    }
                    continuation.resume(
                        throwing: LXScriptError.requestTimedOut
                    )
                }
            }
        }
    }

    func shutdown() {
        queue.async {
            self.isShutdown = true
            self.httpTasks.values.forEach { $0.cancel() }
            self.httpTasks.removeAll()
            self.timerWorkItems.values.forEach { $0.cancel() }
            self.timerWorkItems.removeAll()

            let pending = self.musicContinuations
            self.musicContinuations.removeAll()
            pending.values.forEach {
                $0.resume(throwing: CancellationError())
            }
            self.finishInitialization(
                .failure(LXScriptError.initializationFailed("运行时已关闭"))
            )
            self.descriptor = nil
            self.context = nil
        }
    }

    // MARK: - Context construction

    private func makeContext() throws -> JSContext {
        guard let context = JSContext() else {
            throw LXScriptError.unavailable
        }
        context.exceptionHandler = { _, _ in }

        let send: @convention(block) (String, String) -> Void = {
            [weak self] event, json in
            self?.enqueue { self?.handleSend(event: event, json: json) }
        }
        let request: @convention(block) (String, String, String) -> Void = {
            [weak self] requestID, url, options in
            self?.enqueue {
                self?.handleHTTPRequest(
                    requestID: requestID,
                    urlString: url,
                    optionsJSON: options
                )
            }
        }
        let cancel: @convention(block) (String) -> Void = {
            [weak self] requestID in
            self?.enqueue { self?.cancelHTTPRequest(requestID) }
        }
        let log: @convention(block) (String, String) -> Void = {
            level, message in
            print("[LX][\(level)] \(message)")
        }
        let resolveMusic: @convention(block) (String, String, String) -> Void = {
            [weak self] requestID, error, result in
            self?.enqueue {
                self?.finishMusicRequest(
                    requestID,
                    error: error,
                    result: result
                )
            }
        }
        let setTimer: @convention(block) (String, Double) -> Void = {
            [weak self] timerID, milliseconds in
            self?.enqueue {
                self?.scheduleTimer(timerID, milliseconds: milliseconds)
            }
        }
        let clearTimer: @convention(block) (String) -> Void = {
            [weak self] timerID in
            self?.enqueue { self?.cancelTimer(timerID) }
        }
        let md5: @convention(block) (String) -> String = { value in
            let digest = Insecure.MD5.hash(data: Data(value.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let randomBytes: @convention(block) (Double) -> [Int] = { size in
            let count = max(0, min(Int(size), 65_536))
            var bytes = [UInt8](repeating: 0, count: count)
            if count > 0 {
                _ = SecRandomCopyBytes(
                    kSecRandomDefault,
                    count,
                    &bytes
                )
            }
            return bytes.map(Int.init)
        }

        context.setObject(send, forKeyedSubscript: "__lxSend" as NSString)
        context.setObject(request, forKeyedSubscript: "__lxRequest" as NSString)
        context.setObject(cancel, forKeyedSubscript: "__lxCancel" as NSString)
        context.setObject(log, forKeyedSubscript: "__lxLog" as NSString)
        context.setObject(
            resolveMusic,
            forKeyedSubscript: "__lxResolveMusic" as NSString
        )
        context.setObject(
            setTimer,
            forKeyedSubscript: "__lxSetTimeout" as NSString
        )
        context.setObject(
            clearTimer,
            forKeyedSubscript: "__lxClearTimeout" as NSString
        )
        context.setObject(md5, forKeyedSubscript: "__lxMD5" as NSString)
        context.setObject(
            randomBytes,
            forKeyedSubscript: "__lxRandomBytes" as NSString
        )
        return context
    }

    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func evaluate(_ script: String) throws {
        guard let context else {
            throw LXScriptError.notInitialized
        }
        context.exception = nil
        context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            throw LXScriptError.javaScript(
                exception.toString() ?? "unknown error"
            )
        }
    }

    private func armInitializationTimeout() {
        queue.asyncAfter(deadline: .now() + 6) {
            guard self.initContinuation != nil else { return }
            self.finishInitialization(
                .failure(LXScriptError.initializationTimedOut)
            )
        }
    }

    private func finishInitialization(
        _ result: Result<LXScriptDescriptor, Error>
    ) {
        guard let continuation = initContinuation else { return }
        initContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - LX events

    private func handleSend(event: String, json: String) {
        if event == "updateAlert" {
            updateAlert = Self.dictionary(from: json)
            return
        }
        guard event == "inited" else { return }
        guard let payload = Self.dictionary(from: json) else {
            finishInitialization(
                .failure(LXScriptError.invalidResponse)
            )
            return
        }
        if let status = payload["status"] as? Bool, status == false {
            finishInitialization(
                .failure(
                    LXScriptError.initializationFailed(
                        payload["message"] as? String ?? "inited status=false"
                    )
                )
            )
            return
        }

        let sourceObjects = payload["sources"] as? [String: Any] ?? [:]
        var sources: [LXSourceCapability] = []
        for (id, value) in sourceObjects {
            guard let dictionary = value as? [String: Any] else {
                continue
            }
            sources.append(
                LXSourceCapability(
                    id: id,
                    name: dictionary["name"] as? String ?? id,
                    type: dictionary["type"] as? String ?? "music",
                    actions: dictionary["actions"] as? [String] ?? [],
                    qualitys: dictionary["qualitys"] as? [String] ?? []
                )
            )
        }
        sources.sort { $0.id < $1.id }

        let descriptor = LXScriptDescriptor(
            script: scriptInfo ?? .empty,
            sources: sources
        )
        self.descriptor = descriptor
        finishInitialization(.success(descriptor))
    }

    // MARK: - HTTP bridge

    private func handleHTTPRequest(
        requestID: String,
        urlString: String,
        optionsJSON: String
    ) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            respondHTTP(
                requestID: requestID,
                error: "invalid url",
                response: [:]
            )
            return
        }

        let options = Self.dictionary(from: optionsJSON) ?? [:]
        let timeout = Self.timeout(from: options)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = (
            options["method"] as? String
        )?.uppercased() ?? "GET"

        if let headers = options["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue(
                    String(describing: value),
                    forHTTPHeaderField: key
                )
            }
        }

        if let body = options["body"] {
            if let string = body as? String {
                request.httpBody = Data(string.utf8)
            } else if let dictionary = body as? [String: Any],
                      let data = try? JSONSerialization.data(
                        withJSONObject: dictionary
                      ) {
                request.httpBody = data
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue(
                        "application/json",
                        forHTTPHeaderField: "Content-Type"
                    )
                }
            }
        } else if let form = options["form"] as? [String: Any] {
            request.httpBody = Data(
                Self.formEncoded(form).utf8
            )
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let task = session.dataTask(with: request) {
            [weak self] data, response, error in
            guard let self else { return }
            self.enqueue {
                self.httpTasks[requestID] = nil
                if let error {
                    self.respondHTTP(
                        requestID: requestID,
                        error: error.localizedDescription,
                        response: [:]
                    )
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                if let rawHeaders = http?.allHeaderFields {
                    for (key, value) in rawHeaders {
                        guard let key = key as? String else { continue }
                        headers[key.lowercased()] = String(
                            describing: value
                        )
                    }
                }

                let bodyText = data.flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? ""
                let bodyValue: Any
                if let data,
                   let parsed = try? JSONSerialization.jsonObject(
                    with: data
                   ) {
                    bodyValue = parsed
                } else {
                    bodyValue = bodyText
                }

                let payload: [String: Any] = [
                    "statusCode": http?.statusCode ?? -1,
                    "statusMessage": http.map {
                        HTTPURLResponse.localizedString(
                            forStatusCode: $0.statusCode
                        )
                    } ?? "",
                    "headers": headers,
                    "body": bodyValue,
                    "url": http?.url?.absoluteString
                        ?? url.absoluteString,
                    "bytes": data?.count ?? 0,
                ]
                self.respondHTTP(
                    requestID: requestID,
                    error: "",
                    response: payload
                )
            }
        }
        httpTasks[requestID] = task
        task.resume()
    }

    private func respondHTTP(
        requestID: String,
        error: String,
        response: [String: Any]
    ) {
        guard let context else { return }
        let json = (try? Self.jsonString(response)) ?? "{}"
        context.exception = nil
        context.objectForKeyedSubscript("__lxOnResponse")?
            .call(withArguments: [requestID, error, json])
        context.exception = nil
    }

    private func cancelHTTPRequest(_ requestID: String) {
        httpTasks[requestID]?.cancel()
        httpTasks[requestID] = nil
    }

    private func finishMusicRequest(
        _ requestID: String,
        error: String,
        result: String
    ) {
        guard let continuation = musicContinuations.removeValue(
            forKey: requestID
        ) else {
            return
        }
        if !error.isEmpty {
            continuation.resume(
                throwing: LXScriptError.javaScript(error)
            )
            return
        }
        let trimmed = result.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count <= 2_048,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            continuation.resume(throwing: LXScriptError.invalidURL)
            return
        }
        continuation.resume(returning: trimmed)
    }

    // MARK: - Timers

    private func scheduleTimer(
        _ timerID: String,
        milliseconds: Double
    ) {
        cancelTimer(timerID)
        let delay = min(max(milliseconds, 0), 300_000) / 1_000
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.timerWorkItems[timerID] = nil
            self.context?.objectForKeyedSubscript("__lxTimerFired")?
                .call(withArguments: [timerID])
        }
        timerWorkItems[timerID] = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelTimer(_ timerID: String) {
        timerWorkItems[timerID]?.cancel()
        timerWorkItems[timerID] = nil
    }

    // MARK: - Helpers

    private static func dictionary(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw LXScriptError.invalidResponse
        }
        return string
    }

    private static func timeout(from options: [String: Any]) -> TimeInterval {
        let raw: Double
        if let value = options["timeout"] as? Double {
            raw = value
        } else if let value = options["timeout"] as? Int {
            raw = Double(value)
        } else {
            raw = 20_000
        }
        return min(max(raw / 1_000, 1), 60)
    }

    private static func formEncoded(_ form: [String: Any]) -> String {
        form.map { key, value in
            "\(escape(key))=\(escape(String(describing: value)))"
        }
        .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) ?? value
    }
}
