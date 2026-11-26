import Foundation
import Observation

@MainActor
@Observable
final class LXSourceStore {
    private(set) var sources: [LXSource] = []
    /// Diagnostic changes such as lastError do not change playback authority.
    private(set) var configurationRevision: UInt64 = 0
    private(set) var isWorking = false
    var errorMessage: String?

    @ObservationIgnored
    private let fileURL: URL

    @ObservationIgnored
    private let session: URLSession

    @ObservationIgnored
    private var preloadCache: String?

    init(
        session: URLSession = .shared,
        fileURL: URL? = nil
    ) {
        self.session = session
        self.fileURL = fileURL
            ?? AppStorageLocations.applicationSupportRoot()
                .appending(
                    path: "LXSources.json",
                    directoryHint: .notDirectory
                )
        load()
    }

    var enabledQQSources: [LXSource] {
        sources
            .filter { $0.isEnabled && $0.qqCapability != nil }
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.name < rhs.name
                }
                return lhs.priority < rhs.priority
            }
    }

    var hasQQSource: Bool {
        !enabledQQSources.isEmpty
    }

    func loadPreload() throws -> String {
        if let preloadCache {
            return preloadCache
        }
        let value = try LXScriptRuntime.loadDefaultPreload()
        preloadCache = value
        return value
    }

    // MARK: - Import

    func addScriptURL(_ value: String) async {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = LXSourceError.invalidURL.localizedDescription
            return
        }

        await perform {
            let script = try await self.downloadScript(from: url)
            try await self.importScript(script, scriptURL: trimmed)
        }
    }

    func addScriptFile(_ url: URL) async {
        await perform {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            guard let script = String(data: data, encoding: .utf8) else {
                throw LXSourceError.invalidScript
            }
            try await self.importScript(
                script,
                scriptURL: nil,
                nameHint: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    func addSourceList(_ value: String) async {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = LXSourceError.invalidURL.localizedDescription
            return
        }

        await perform {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("MeloX/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw LXSourceError.downloadFailed
            }
            let object = try JSONSerialization.jsonObject(with: data)
            let links = Self.sourceLinks(in: object)
            guard !links.isEmpty else {
                throw LXSourceError.emptySourceList
            }
            for link in links.prefix(50) {
                do {
                    let script = try await self.downloadScript(
                        from: URL(string: link)!
                    )
                    try await self.importScript(script, scriptURL: link)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Management

    func remove(_ source: LXSource) {
        guard sources.contains(where: { $0.id == source.id }) else { return }
        sources.removeAll { $0.id == source.id }
        normalizePriorities()
        save()
    }

    func setEnabled(_ source: LXSource, isEnabled: Bool) {
        guard let index = sources.firstIndex(
            where: { $0.id == source.id }
        ) else { return }
        guard sources[index].isEnabled != isEnabled else { return }
        sources[index].isEnabled = isEnabled
        save()
    }

    func move(_ source: LXSource, offset: Int) {
        guard let index = sources.firstIndex(
            where: { $0.id == source.id }
        ) else { return }
        let target = index + offset
        guard sources.indices.contains(target) else { return }
        sources.swapAt(index, target)
        normalizePriorities()
        save()
    }

    func refresh(_ source: LXSource) async {
        await perform {
            let runtime = LXScriptRuntime(preload: try self.loadPreload(), session: self.session)
            defer { runtime.shutdown() }
            do {
                let descriptor = try await runtime.initialize(script: source.rawScript)
                guard let index = self.sources.firstIndex(where: {
                    $0.id == source.id && $0.rawScript == source.rawScript
                }) else { return }
                self.sources[index].capabilities = descriptor.sources
                self.sources[index].name = descriptor.script.name
                self.sources[index].version = descriptor.script.version
                self.sources[index].author = descriptor.script.author
                self.sources[index].homepage = descriptor.script.homepage
                self.sources[index].lastError = nil
                self.sources[index].updatedAt = Date()
                self.save()
            } catch {
                self.updateAfterRuntimeFailure(source, error: error)
            }
        }
    }

    func updateAfterRuntimeFailure(_ source: LXSource, error: Error) {
        guard let index = sources.firstIndex(
            where: { $0.id == source.id && $0.rawScript == source.rawScript }
        ) else { return }
        sources[index].lastError = error.localizedDescription
        save(configurationChanged: false)
    }

    // MARK: - Private

    private func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadScript(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("MeloX/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LXSourceError.downloadFailed
        }
        guard var script = String(data: data, encoding: .utf8) else {
            throw LXSourceError.invalidScript
        }
        if script.hasPrefix("\u{FEFF}") {
            script.removeFirst()
        }
        return script
    }

    private func importScript(
        _ script: String,
        scriptURL: String?,
        nameHint: String? = nil
    ) async throws {
        let info = LXScriptInfo.parse(script)
        let runtime = LXScriptRuntime(preload: try loadPreload(), session: session)
        let descriptor: LXScriptDescriptor
        do {
            descriptor = try await runtime.initialize(
                script: script,
                info: info
            )
        } catch {
            runtime.shutdown()
            throw error
        }
        runtime.shutdown()

        guard descriptor.qqSource != nil else {
            throw LXSourceError.noQQSource
        }

        let resolvedName = info.name.isEmpty
            ? (nameHint ?? "未命名音源")
            : info.name

        if let scriptURL,
           let index = sources.firstIndex(
            where: { $0.scriptURL == scriptURL }
           ) {
            sources[index].name = resolvedName
            sources[index].rawScript = script
            sources[index].version = info.version
            sources[index].author = info.author
            sources[index].homepage = info.homepage
            sources[index].capabilities = descriptor.sources
            sources[index].lastError = nil
            sources[index].updatedAt = Date()
        } else {
            let priority = (sources.map(\.priority).max() ?? -1) + 1
            sources.append(
                LXSource(
                    name: resolvedName,
                    scriptURL: scriptURL,
                    rawScript: script,
                    version: info.version,
                    author: info.author,
                    homepage: info.homepage,
                    capabilities: descriptor.sources,
                    priority: priority
                )
            )
        }
        normalizePriorities()
        save()
    }

    private func normalizePriorities() {
        for index in sources.indices {
            sources[index].priority = index
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sources = ((try? decoder.decode([LXSource].self, from: data)) ?? [])
            .sorted { $0.priority < $1.priority }
        normalizePriorities()
    }

    private func save(configurationChanged: Bool = true) {
        if configurationChanged { configurationRevision &+= 1 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(sources)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func sourceLinks(in object: Any) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func walk(_ value: Any, depth: Int) {
            guard depth < 4, result.count < 100 else { return }
            if let string = value as? String {
                if string.hasPrefix("http://")
                    || string.hasPrefix("https://") {
                    if seen.insert(string).inserted {
                        result.append(string)
                    }
                }
                return
            }
            if let array = value as? [Any] {
                for item in array {
                    walk(item, depth: depth + 1)
                }
                return
            }
            if let dictionary = value as? [String: Any] {
                for key in ["url", "link", "script", "src"] {
                    if let string = dictionary[key] as? String,
                       string.hasPrefix("http://")
                        || string.hasPrefix("https://") {
                        if seen.insert(string).inserted {
                            result.append(string)
                        }
                    }
                }
                for key in ["sources", "data", "list", "items"] {
                    if let nested = dictionary[key] {
                        walk(nested, depth: depth + 1)
                    }
                }
            }
        }

        walk(object, depth: 0)
        return result
    }
}
