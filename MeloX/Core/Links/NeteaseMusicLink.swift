import Foundation

struct NeteaseListenTogetherLink: Hashable, Identifiable {
    let invitationText: String
    let roomID: String

    var id: String { roomID }
}

enum NeteaseMusicLink: Hashable, Identifiable {
    case song(id: Int)
    case listenTogether(NeteaseListenTogetherLink)

    var id: String {
        switch self {
        case .song(let id):
            "song-\(id)"
        case .listenTogether(let invitation):
            "listen-together-\(invitation.roomID)"
        }
    }
}

enum NeteaseMusicLinkParser {
    static func parse(_ text: String) -> NeteaseMusicLink? {
        // QQ 音乐模式不再识别网易云深链；QQ 分享链接解析留待后续实现。
        return nil
    }

    private static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return URL(string: text).map { [$0] } ?? []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls = detector.matches(
            in: text,
            options: [],
            range: range
        ).compactMap(\.url)

        if let directURL = URL(string: text),
           !urls.contains(directURL) {
            urls.append(directURL)
        }
        return urls
    }

    private static func isNeteaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "music.163.com"
            || host.hasSuffix(".music.163.com")
    }

    private static func isListenTogetherURL(_ url: URL) -> Bool {
        url.path.lowercased().contains("/listen-together/")
    }

    private static func songID(from url: URL) -> Int? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        if isSongPath(components.path),
           let id = positiveID(in: components.queryItems ?? []) {
            return id
        }

        guard let fragment = components.fragment else { return nil }
        let fragmentPath = fragment.hasPrefix("/")
            ? fragment
            : "/\(fragment)"
        guard let fragmentComponents = URLComponents(
            string: "https://music.163.com\(fragmentPath)"
        ), isSongPath(fragmentComponents.path) else {
            return nil
        }
        return positiveID(in: fragmentComponents.queryItems ?? [])
    }

    private static func isSongPath(_ path: String) -> Bool {
        switch path.lowercased() {
        case "/song", "/m/song":
            true
        default:
            false
        }
    }

    private static func positiveID(
        in queryItems: [URLQueryItem]
    ) -> Int? {
        guard let value = queryItems.first(where: {
            $0.name.caseInsensitiveCompare("id") == .orderedSame
        })?.value,
              let id = Int(value),
              id > 0 else {
            return nil
        }
        return id
    }
}
