import Foundation

nonisolated enum QQLoginQRKind: Sendable {
    case qq
    case wechat
}

nonisolated struct QQLoginQRCode: Sendable {
    let kind: QQLoginQRKind
    let imageData: Data
    let mimeType: String
    let identifier: String
}

nonisolated enum QQLoginQRState: Sendable {
    case waiting
    case scanned
    case confirmed
    case expired
    case refused
    case credential(QQCredential)
}

nonisolated struct QQPhoneAuthResult: Sendable {
    enum State: Sendable {
        case sent
        case captcha
        case frequency
    }

    let state: State
    let securityURL: String?
}

nonisolated enum QQLoginError: LocalizedError, Sendable {
    case invalidResponse
    case qrUnavailable
    case loginFailed(code: Int, message: String?)
    case captchaRequired(String?)
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "QQ 音乐返回了无法解析的数据。"
        case .qrUnavailable:
            "获取二维码失败。"
        case .loginFailed(let code, let message):
            if let message, !message.isEmpty {
                "QQ 音乐登录失败（\(code)）：\(message)"
            } else {
                "QQ 音乐登录失败（\(code)）。"
            }
        case .captchaRequired(let url):
            if let url, !url.isEmpty {
                "需要完成人机验证：\(url)"
            } else {
                "需要完成人机验证。"
            }
        case .missingCredential:
            "登录成功但没有拿到有效凭证。"
        }
    }
}

/// QQ 音乐登录：QQ 扫码、微信扫码、手机验证码。
///
/// 流程与 `QQMusicApi/qqmusic_api/modules/login.py` 对齐。二维码与
/// 授权请求使用独立会话保存 Cookie；最后的凭证交换走 `musicu.fcg`。
@MainActor
final class QQLoginService {
    private let blocker = QQRedirectBlocker()
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let ownsSession: Bool
    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    init(session injectedSession: URLSession? = nil) {
        if let injectedSession {
            session = injectedSession
            cookieStorage = injectedSession.configuration.httpCookieStorage ?? .shared
            ownsSession = false
            return
        }
        ownsSession = true
        let storage = HTTPCookieStorage.shared
        storage.cookieAcceptPolicy = .always
        cookieStorage = storage

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        session = URLSession(
            configuration: configuration,
            delegate: blocker,
            delegateQueue: nil
        )
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    // MARK: - QQ QR

    func fetchQQQRCode() async throws -> QQLoginQRCode {
        let timestamp = String(Double.random(in: 0..<1))
        let url = "https://ssl.ptlogin2.qq.com/ptqrshow"
        let query = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: timestamp),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        let (data, response, _) = try await perform(
            method: "GET",
            urlString: url,
            query: query,
            headers: ["Referer": "https://xui.ptlogin2.qq.com/"]
        )
        guard response.statusCode == 200, !data.isEmpty else {
            throw QQLoginError.qrUnavailable
        }
        guard let qrsig = cookieValue(named: "qrsig"), !qrsig.isEmpty else {
            throw QQLoginError.qrUnavailable
        }
        return QQLoginQRCode(
            kind: .qq,
            imageData: data,
            mimeType: "image/png",
            identifier: qrsig
        )
    }

    func pollQQQRCode(_ qr: QQLoginQRCode) async throws -> QQLoginQRState {
        let hash = Self.hash33(qr.identifier)
        let milliseconds = Int(Date().timeIntervalSince1970 * 1_000)
        let query = [
            URLQueryItem(
                name: "u1",
                value: "https://graph.qq.com/oauth2.0/login_jump"
            ),
            URLQueryItem(name: "ptqrtoken", value: String(hash)),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(
                name: "action",
                value: "0-0-\(milliseconds)"
            ),
            URLQueryItem(name: "js_ver", value: "20102616"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "has_onekey", value: "1"),
        ]
        let (data, _, _) = try await perform(
            method: "GET",
            urlString: "https://ssl.ptlogin2.qq.com/ptqrlogin",
            query: query,
            headers: [
                "Referer": "https://xui.ptlogin2.qq.com/",
                "Cookie": "qrsig=\(qr.identifier)",
            ]
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let parsed = Self.parseQQCallback(text) else {
            throw QQLoginError.invalidResponse
        }
        guard let code = Int(parsed.args.first ?? "") else {
            throw QQLoginError.invalidResponse
        }

        switch code {
        case 66, 408:
            return .waiting
        case 67, 404:
            return .scanned
        case 65, 402:
            return .expired
        case 68, 403:
            return .refused
        case 0, 405:
            guard parsed.args.count >= 3,
                  let redirect = URL(string: parsed.args[2]),
                  let queryItems = URLComponents(
                    url: redirect,
                    resolvingAgainstBaseURL: false
                  )?.queryItems,
                  let uin = queryItems.first(
                    where: { $0.name == "uin" }
                  )?.value,
                  let sigx = queryItems.first(
                    where: { $0.name == "ptsigx" }
                  )?.value else {
                throw QQLoginError.invalidResponse
            }
            let credential = try await authorizeQQQR(
                uin: uin,
                sigx: sigx
            )
            return .credential(credential)
        default:
            throw QQLoginError.loginFailed(code: code, message: nil)
        }
    }

    // MARK: - WeChat QR

    func fetchWeChatQRCode() async throws -> QQLoginQRCode {
        let redirect = "https://y.qq.com/portal/wx_redirect.html" +
            "?login_type=2&surl=https://y.qq.com/"
        let query = [
            URLQueryItem(name: "appid", value: "wx48db31d50e334801"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "snsapi_login"),
            URLQueryItem(name: "state", value: "STATE"),
            URLQueryItem(
                name: "href",
                value: "https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect"
            ),
        ]
        guard var components = URLComponents(
            string: "https://open.weixin.qq.com/connect/qrconnect"
        ) else {
            throw QQLoginError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else {
            throw QQLoginError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let html = String(data: data, encoding: .utf8),
              let uuid = Self.firstMatch(
                #"uuid=([^"&]+)"#,
                in: html
              ) else {
            throw QQLoginError.qrUnavailable
        }

        guard let imageURL = URL(
            string: "https://open.weixin.qq.com/connect/qrcode/\(uuid)"
        ) else {
            throw QQLoginError.qrUnavailable
        }
        var imageRequest = URLRequest(url: imageURL, timeoutInterval: 25)
        imageRequest.setValue(
            "https://open.weixin.qq.com/connect/qrconnect",
            forHTTPHeaderField: "Referer"
        )
        imageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (imageData, imageResponse) = try await URLSession.shared.data(
            for: imageRequest
        )
        guard let imageHTTP = imageResponse as? HTTPURLResponse,
              imageHTTP.statusCode == 200,
              !imageData.isEmpty else {
            throw QQLoginError.qrUnavailable
        }
        return QQLoginQRCode(
            kind: .wechat,
            imageData: imageData,
            mimeType: "image/jpeg",
            identifier: uuid
        )
    }

    func pollWeChatQRCode(_ qr: QQLoginQRCode) async throws -> QQLoginQRState {
        guard var components = URLComponents(
            string: "https://lp.open.weixin.qq.com/connect/l/qrconnect"
        ) else {
            throw QQLoginError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "uuid", value: qr.identifier),
            URLQueryItem(
                name: "_",
                value: String(Int(Date().timeIntervalSince1970) * 1_000)
            ),
        ]
        guard let url = components.url else {
            throw QQLoginError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue(
            "https://open.weixin.qq.com/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError
            where error.code == .timedOut {
            return .waiting
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        guard let errorCodeText = Self.firstMatch(
            #"window\.wx_errcode=(\d+)"#,
            in: text
        ), let errorCode = Int(errorCodeText) else {
            throw QQLoginError.invalidResponse
        }

        switch errorCode {
        case 66, 408:
            return .waiting
        case 67, 404:
            return .scanned
        case 65, 402:
            return .expired
        case 68, 403:
            return .refused
        case 0, 405:
            guard let code = Self.firstMatch(
                #"window\.wx_code='([^']*)'"#,
                in: text
            ), !code.isEmpty else {
                throw QQLoginError.invalidResponse
            }
            let credential = try await authorizeWeChat(code: code)
            return .credential(credential)
        default:
            throw QQLoginError.loginFailed(
                code: errorCode,
                message: nil
            )
        }
    }

    // MARK: - Phone

    func sendPhoneAuthCode(
        phone: String,
        countryCode: Int = 86
    ) async throws -> QQPhoneAuthResult {
        let payload = try await loginCGI(
            module: "music.login.LoginServer",
            method: "SendPhoneAuthCode",
            parameter: [
                "tmeAppid": "qqmusic",
                "areaCode": String(countryCode),
                "phoneNo": phone,
            ],
            comm: ["tmeLoginMethod": 3],
            allowsErrorCodes: true
        )
        let code = payload.code
        switch code {
        case 0, 200:
            return QQPhoneAuthResult(state: .sent, securityURL: nil)
        case 20_276:
            return QQPhoneAuthResult(
                state: .captcha,
                securityURL: Self.string(payload.data["securityURL"])
            )
        case 100_001:
            return QQPhoneAuthResult(state: .frequency, securityURL: nil)
        default:
            throw QQLoginError.loginFailed(
                code: code,
                message: Self.string(payload.data["message"])
            )
        }
    }

    func authorizePhone(
        phone: String,
        code: String
    ) async throws -> QQCredential {
        let payload = try await loginCGI(
            module: "music.login.LoginServer",
            method: "Login",
            parameter: [
                "code": code,
                "loginMode": 1,
                "phoneNo": phone,
            ],
            comm: ["tmeLoginMethod": 3, "tmeLoginType": 0]
        )
        return try Self.credential(from: payload.merged)
    }

    func refresh(_ credential: QQCredential) async throws -> QQCredential {
        guard !credential.refreshKey.isEmpty,
              !credential.refreshToken.isEmpty else {
            throw QQLoginError.missingCredential
        }
        let payload = try await loginCGI(
            module: "music.login.LoginServer",
            method: "Login",
            parameter: [
                "refresh_key": credential.refreshKey,
                "refresh_token": credential.refreshToken,
                "musicid": credential.musicID,
            ],
            comm: ["tmeLoginType": credential.loginType]
        )
        return try Self.credential(from: payload.merged)
    }

    // MARK: - Authorization

    private func authorizeQQQR(
        uin: String,
        sigx: String
    ) async throws -> QQCredential {
        let query = [
            URLQueryItem(name: "uin", value: uin),
            URLQueryItem(name: "pttype", value: "1"),
            URLQueryItem(name: "service", value: "ptqrlogin"),
            URLQueryItem(name: "nodirect", value: "0"),
            URLQueryItem(name: "ptsigx", value: sigx),
            URLQueryItem(
                name: "s_url",
                value: "https://graph.qq.com/oauth2.0/login_jump"
            ),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "ptredirect", value: "100"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "j_later", value: "0"),
            URLQueryItem(name: "low_login_hour", value: "0"),
            URLQueryItem(name: "regmaster", value: "0"),
            URLQueryItem(name: "pt_login_type", value: "3"),
            URLQueryItem(name: "pt_aid", value: "0"),
            URLQueryItem(name: "pt_aaid", value: "16"),
            URLQueryItem(name: "pt_light", value: "0"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        _ = try await perform(
            method: "GET",
            urlString: "https://ssl.ptlogin2.graph.qq.com/check_sig",
            query: query,
            headers: ["Referer": "https://xui.ptlogin2.qq.com/"]
        )

        guard let pSkey = cookieValue(named: "p_skey"),
              !pSkey.isEmpty else {
            throw QQLoginError.invalidResponse
        }

        let redirectURL = "https://y.qq.com/portal/wx_redirect.html" +
            "?login_type=1&surl=https://y.qq.com/"
        let form = [
            "response_type": "code",
            "client_id": "100497308",
            "redirect_uri": redirectURL,
            "scope": "get_user_info,get_app_friends",
            "state": "state",
            "switch": "",
            "from_ptlogin": "1",
            "src": "1",
            "update_auth": "1",
            "openapi": "1010_1030",
            "g_tk": String(Self.hash33(pSkey, seed: 5381)),
            "auth_time": String(Int(Date().timeIntervalSince1970) * 1_000),
            "ui": UUID().uuidString.lowercased(),
        ]
        let (_, response, location) = try await perform(
            method: "POST",
            urlString: "https://graph.qq.com/oauth2.0/authorize",
            headers: [
                "Referer": "https://xui.ptlogin2.qq.com/",
                "Cookie": cookieHeader(),
            ],
            form: form
        )
        let redirect = location
            ?? response.value(forHTTPHeaderField: "Location")
            ?? ""
        guard let code = Self.queryValue(
            named: "code",
            in: redirect
        ), !code.isEmpty else {
            throw QQLoginError.invalidResponse
        }

        let payload = try await loginCGI(
            module: "QQConnectLogin.LoginServer",
            method: "QQLogin",
            parameter: ["code": code],
            comm: ["tmeLoginType": 2]
        )
        return try Self.credential(from: payload.merged)
    }

    private func authorizeWeChat(code: String) async throws -> QQCredential {
        let payload = try await loginCGI(
            module: "music.login.LoginServer",
            method: "Login",
            parameter: [
                "code": code,
                "strAppid": "wx48db31d50e334801",
            ],
            comm: ["tmeLoginType": 1]
        )
        return try Self.credential(from: payload.merged)
    }

    // MARK: - CGI

    private struct LoginCGIResult {
        let code: Int
        let data: [String: Any]

        var merged: [String: Any] {
            var result = data
            if let nested = data["data"] as? [String: Any] {
                for (key, value) in nested {
                    result[key] = value
                }
            }
            result["code"] = code
            return result
        }
    }

    private func loginCGI(
        module: String,
        method: String,
        parameter: [String: Any],
        comm: [String: Any],
        allowsErrorCodes: Bool = false
    ) async throws -> LoginCGIResult {
        let guid = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let qimeiSuffix = String(
            format: "%04x",
            UInt16.random(in: 0...UInt16.max)
        )
        var baseComm: [String: Any] = [
            "ct": 11,
            "cv": "20090008",
            "v": "20090008",
            "chid": "10003505",
            "qq": guid,
            "tmeAppID": "qqmusic",
            "traceid": "10002_\(guid)_\(Int(Date().timeIntervalSince1970))",
            "QIMEI36": String((guid + qimeiSuffix).prefix(36)),
            "OpenUDID": guid,
            "udid": guid,
            "aid": String(guid.prefix(16)),
            "os_ver": "15",
            "phonetype": "iPhone",
        ]
        for (key, value) in comm {
            baseComm[key] = value
        }

        let payload: [String: Any] = [
            "comm": baseComm,
            "req_0": [
                "module": module,
                "method": method,
                "param": parameter,
            ],
        ]
        var request = URLRequest(
            url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!,
            timeoutInterval: 25
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "QQMusic 20090008(android 15)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw QQLoginError.invalidResponse
        }
        let requestPayload = json["req_0"] as? [String: Any]
        let code = requestPayload?["code"] as? Int
            ?? json["code"] as? Int
            ?? -1
        let resultData = (requestPayload?["data"] as? [String: Any])
            ?? (json["data"] as? [String: Any])
            ?? [:]
        if !allowsErrorCodes, code != 0, code != 200 {
            let message = (requestPayload?["msg"] as? String)
                ?? (json["message"] as? String)
            throw QQLoginError.loginFailed(code: code, message: message)
        }
        return LoginCGIResult(code: code, data: resultData)
    }

    // MARK: - HTTP

    private func perform(
        method: String,
        urlString: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        form: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse, String?) {
        guard var components = URLComponents(string: urlString) else {
            throw QQLoginError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw QQLoginError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let form {
            request.httpBody = form.map {
                "\(Self.escape($0.key))=\(Self.escape($0.value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
        }

        blocker.reset()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QQLoginError.invalidResponse
        }
        return (data, http, blocker.takeLocation())
    }

    private func cookieValue(named name: String) -> String? {
        cookieStorage.cookies?
            .first { $0.name == name && $0.domain.contains("qq.com") }?
            .value
    }

    private func cookieHeader() -> String {
        let cookies = cookieStorage.cookies?
            .filter { $0.domain.contains("qq.com") } ?? []
        return cookies.map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: - Parsing

    private static func credential(
        from payload: [String: Any]
    ) throws -> QQCredential {
        let musicID = int(payload["musicid"])
            ?? int(payload["str_musicid"])
            ?? int(payload["musicId"])
            ?? 0
        let musicKey = string(payload["musickey"])
            ?? string(payload["musicKey"])
            ?? ""
        guard musicID > 0, !musicKey.isEmpty else {
            throw QQLoginError.missingCredential
        }

        let inferredLoginType = musicKey.hasPrefix("W_X") ? 1 : 2
        return QQCredential(
            musicID: musicID,
            musicKey: musicKey,
            refreshKey: string(payload["refresh_key"]) ?? "",
            refreshToken: string(payload["refresh_token"]) ?? "",
            openID: string(payload["openid"]) ?? "",
            accessToken: string(payload["access_token"]) ?? "",
            encryptUIN: string(payload["encryptUin"])
                ?? string(payload["encrypt_uin"])
                ?? string(payload["encryptuin"])
                ?? "",
            loginType: int(payload["loginType"]) ?? inferredLoginType,
            expiredAt: int(payload["expired_at"]) ?? 0,
            musicKeyCreateTime: int(payload["musickeyCreateTime"]) ?? 0,
            keyExpiresIn: int(payload["keyExpiresIn"]) ?? 0
        )
    }

    private static func parseQQCallback(
        _ text: String
    ) -> (args: [String], raw: String)? {
        guard let open = text.range(of: "ptuiCB("),
              let close = text.range(of: ")", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let body = String(text[open.upperBound..<close.lowerBound])
        let pattern = #"'((?:\\.|[^'])*)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let args = regex.matches(in: body, range: range).compactMap {
            match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: body) else {
                return nil
            }
            return String(body[valueRange])
        }
        return (args, body)
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private static func queryValue(
        named name: String,
        in urlString: String
    ) -> String? {
        guard let components = URLComponents(string: urlString) else {
            return nil
        }
        return components.queryItems?
            .first { $0.name == name }?
            .value
    }

    private static func hash33(_ value: String, seed: Int = 0) -> Int {
        var hash = UInt64(seed)
        for scalar in value.unicodeScalars {
            hash = (hash << 5) &+ hash &+ UInt64(scalar.value)
        }
        return Int(hash & 0x7fff_ffff)
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) ?? value
    }
}

private final class QQRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var capturedLocation: String?

    func reset() {
        lock.lock()
        capturedLocation = nil
        lock.unlock()
    }

    func takeLocation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = capturedLocation
        capturedLocation = nil
        return value
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        capturedLocation = request.url?.absoluteString
        lock.unlock()
        completionHandler(nil)
    }
}
