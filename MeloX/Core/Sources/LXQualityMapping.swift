import Foundation

nonisolated enum LXQualityMapping {
    /// What a file on QQ's CDN is, read from its name.
    enum FileKind: Equatable, Sendable {
        case tier(MusicQuality)
        /// The short preview QQ serves in place of a song.
        case trialClip
        /// A container or cipher the player cannot decode.
        case undecodable
    }

    /// QQ's tiers from `quality` downward, one step at a time. A song that
    /// lacks the chosen tier plays the next one in this order.
    static func ladder(from quality: MusicQuality) -> [MusicQuality] {
        let tiers = MusicQuality.allCases
        guard let index = tiers.firstIndex(of: quality) else {
            return [quality]
        }
        return Array(tiers[...index].reversed())
    }

    /// The names LX sources use for a tier, preferred first.
    static func sourceNames(for quality: MusicQuality) -> [String] {
        switch quality {
        case .standard: ["128k"]
        case .high: ["320k"]
        case .lossless: ["flac"]
        case .hiResolution: ["hires", "flac24bit"]
        case .highDefinitionSurround: ["atmos"]
        case .immersiveSurround: ["atmos_plus"]
        case .ultraClearMaster: ["master"]
        }
    }

    /// The names to ask one source for, given what it declares. A source
    /// that declares nothing is asked for every name.
    static func sourceNames(
        for quality: MusicQuality,
        declared: [String]
    ) -> [String] {
        let names = sourceNames(for: quality)
        let declared = Set(declared.map { $0.lowercased() })
        guard !declared.isEmpty else { return names }
        return names.filter(declared.contains)
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
    /// QQ names its files by encoding, a four-character code followed by
    /// the media id, so the name tells what a URL really serves.
    static func fileKind(for url: URL) -> FileKind? {
        let pathExtension = url.pathExtension.lowercased()
        if undecodableExtensions.contains(pathExtension) {
            return .undecodable
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 16,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return nil
        }
        switch name.prefix(4).uppercased() {
        case "M500", "C200", "C400", "C600": return .tier(.standard)
        case "M800": return .tier(.high)
        case "F000": return .tier(.lossless)
        case "RS01": return .tier(.hiResolution)
        case "Q000": return .tier(.highDefinitionSurround)
        case "Q001": return .tier(.immersiveSurround)
        case "AI00": return .tier(.ultraClearMaster)
        case "RS02", "O802": return .trialClip
        default: return nil
        }
    }

    /// Ogg and QQ's encrypted containers have no decoder on this platform.
    private static let undecodableExtensions: Set<String> = [
        "ogg", "mgg", "mflac", "mmp4", "mnac", "nac", "ape", "wma",
    ]

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

    static func format(for url: URL, quality: MusicQuality) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension
        }
        switch quality {
        case .standard, .high:
            return "mp3"
        case .lossless, .hiResolution, .highDefinitionSurround,
             .immersiveSurround, .ultraClearMaster:
            return "flac"
        }
    }
}
