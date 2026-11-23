import Foundation

nonisolated enum LXQualityMapping {
    /// 把 MeloX 的 7 档音质映射为 LX/QQ 的 quality 标识。
    /// 返回值按优先级从高到低排列，供自动降级使用。
    static func candidates(
        for quality: MusicQuality,
        supported: [String]
    ) -> [String] {
        let preference: [String]
        switch quality {
        case .standard:
            preference = ["128k"]
        case .high:
            preference = ["320k", "128k"]
        case .lossless:
            preference = ["flac", "320k", "128k"]
        case .hiResolution:
            preference = ["hires", "flac24bit", "flac", "320k", "128k"]
        case .highDefinitionSurround:
            preference = ["atmos", "flac24bit", "flac", "320k", "128k"]
        case .immersiveSurround:
            preference = [
                "atmos_plus", "atmos", "flac24bit", "flac", "320k", "128k",
            ]
        case .ultraClearMaster:
            preference = [
                "master", "flac24bit", "flac", "320k", "128k",
            ]
        }

        let declared = Set(supported.map { $0.lowercased() })
        guard !declared.isEmpty else { return preference }

        let filtered = preference.filter { declared.contains($0) }
        return filtered.isEmpty ? preference : filtered
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
