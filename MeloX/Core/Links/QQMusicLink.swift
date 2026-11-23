import Foundation

enum QQMusicLink: Hashable {
    case song(mid: String)
    case album(mid: String)
    case playlist(id: Int)
    case toplist(id: Int)
}

enum QQMusicLinkParser {
    static func parse(_ text: String) -> QQMusicLink? {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        for url in detectedURLs(in: trimmed) where isQQMusicURL(url) {
            if let link = link(from: url) {
                return link
            }
        }
        return nil
    }

    private static func link(from url: URL) -> QQMusicLink? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let markerIndex = parts.firstIndex(where: {
            ["songDetail", "albumDetail", "playlist", "toplist"]
                .contains($0)
        }), parts.indices.contains(markerIndex + 1) else {
            return nil
        }
        let value = parts[markerIndex + 1]
        switch parts[markerIndex] {
        case "songDetail":
            return value.isEmpty ? nil : .song(mid: value)
        case "albumDetail":
            return value.isEmpty ? nil : .album(mid: value)
        case "playlist":
            return Int(value).map(QQMusicLink.playlist)
        case "toplist":
            return Int(value).map(QQMusicLink.toplist)
        default:
            return nil
        }
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

    private static func isQQMusicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "y.qq.com" || host.hasSuffix(".y.qq.com")
    }
}
