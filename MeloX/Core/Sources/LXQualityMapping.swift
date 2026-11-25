import Foundation

nonisolated enum LXQualityMapping {
    /// 把 MeloX 的 7 档音质映射为 LX/QQ 的 quality 标识。
    /// 返回值按优先级从高到低排列，供自动降级使用。
    static func preference(for quality: MusicQuality) -> [String] {
        switch quality {
        case .standard:
            ["128k"]
        case .high:
            ["320k", "128k"]
        case .lossless:
            ["flac", "320k", "128k"]
        case .hiResolution:
            ["hires", "flac24bit", "flac", "320k", "128k"]
        case .highDefinitionSurround:
            ["atmos", "flac24bit", "flac", "320k", "128k"]
        case .immersiveSurround:
            ["atmos_plus", "atmos", "flac24bit", "flac", "320k", "128k"]
        case .ultraClearMaster:
            ["master", "flac24bit", "flac", "320k", "128k"]
        }
    }

    static func candidates(
        for quality: MusicQuality,
        supported: [String]
    ) -> [String] {
        let preference = preference(for: quality)

        let declared = Set(supported.map { $0.lowercased() })
        guard !declared.isEmpty else { return preference }

        let filtered = preference.filter { declared.contains($0) }
        if !filtered.isEmpty { return filtered }
        // 请求档位与源声明没有交集时，退回源声明中的第一个可用档位，
        // 避免向源请求它明确不支持的音质。
        let fallback = supported
            .map { $0.lowercased() }
            .first { !$0.isEmpty }
        return fallback.map { [$0] } ?? preference
    }

    static func quality(for value: String) -> MusicQuality? {
        switch value.lowercased() {
        case "128k": .standard
        case "320k": .high
        case "flac": .lossless
        case "flac24bit", "hires": .hiResolution
        case "atmos": .highDefinitionSurround
        case "atmos_plus": .immersiveSurround
        case "master": .ultraClearMaster
        default: nil
        }
    }

    /// A source reports the tier it was asked for, not the file it found.
    /// QQ's own CDN names files by encoding, so a stream served from there
    /// tells what is really playing.
    static func verifiedQuality(for url: URL) -> MusicQuality? {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("qq.com") || host.contains("qqmusic") else {
            return nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 12 else { return nil }
        switch name.prefix(4).uppercased() {
        case "M500", "C200", "C400", "C600", "O400", "O600": return .standard
        case "M800", "O800": return .high
        case "F000": return .lossless
        case "RS01": return .hiResolution
        case "Q000": return .highDefinitionSurround
        case "Q001": return .immersiveSurround
        case "AI00": return .ultraClearMaster
        default: return nil
        }
    }

    static func rank(of quality: MusicQuality?) -> Int {
        quality.flatMap(MusicQuality.allCases.firstIndex(of:)) ?? -1
    }

    static func bitrate(for quality: MusicQuality) -> Int? {
        switch quality {
        case .standard: 128_000
        case .high: 320_000
        default: nil
        }
    }

    static func bitrate(for quality: String) -> Int? {
        switch quality.lowercased() {
        case "128k": 128_000
        case "320k": 320_000
        default: nil
        }
    }

    static func format(for url: URL, quality: String) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension
        }
        switch quality.lowercased() {
        case "128k", "320k":
            return "mp3"
        case "flac", "flac24bit", "hires", "master":
            return "flac"
        case "atmos", "atmos_plus":
            return "ogg"
        default:
            return nil
        }
    }
}
