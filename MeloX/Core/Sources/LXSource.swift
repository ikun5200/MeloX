import Foundation

nonisolated struct LXSource: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var scriptURL: String?
    var rawScript: String
    var version: String
    var author: String
    var homepage: String
    var capabilities: [LXSourceCapability]
    var isEnabled: Bool
    var priority: Int
    var lastError: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        scriptURL: String? = nil,
        rawScript: String,
        version: String = "",
        author: String = "",
        homepage: String = "",
        capabilities: [LXSourceCapability] = [],
        isEnabled: Bool = true,
        priority: Int = 0,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.scriptURL = scriptURL
        self.rawScript = rawScript
        self.version = version
        self.author = author
        self.homepage = homepage
        self.capabilities = capabilities
        self.isEnabled = isEnabled
        self.priority = priority
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    var qqCapability: LXSourceCapability? {
        capabilities.first { $0.id == "tx" && $0.supportsMusicURL }
    }

    var qqQualities: [String] {
        qqCapability?.qualitys ?? []
    }

    var maskedScriptURL: String {
        guard let scriptURL else { return "本地脚本" }
        guard var components = URLComponents(string: scriptURL) else {
            return scriptURL
        }
        if components.query != nil {
            components.query = components.queryItems?.map { item -> String in
                let isSecret = ["key", "token", "apikey", "api_key"]
                    .contains(item.name.lowercased())
                let value = isSecret ? "••••••" : (item.value ?? "")
                return "\(item.name)=\(value)"
            }.joined(separator: "&")
        }
        return components.string ?? scriptURL
    }
}

nonisolated enum LXSourceError: LocalizedError, Sendable {
    case invalidURL
    case downloadFailed
    case invalidScript
    case noQQSource
    case emptySourceList

    var errorDescription: String? {
        switch self {
        case .invalidURL: "音源地址无效。"
        case .downloadFailed: "下载音源脚本失败。"
        case .invalidScript: "音源脚本不是有效的 UTF-8 JavaScript。"
        case .noQQSource: "该音源没有提供 QQ 音乐（tx）的播放能力。"
        case .emptySourceList: "没有从源列表中找到可用地址。"
        }
    }
}
