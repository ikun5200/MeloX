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
        let known = declared.compactMap(Self.quality(for:))
        // An absent or completely unrecognized declaration describes no
        // upper bound. Never send arbitrary strings from a declaration.
        guard !known.isEmpty else { return names }
        let declared = Set(declared.map(normalized))
        return names.filter(declared.contains)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func quality(for value: String) -> MusicQuality? {
        switch normalized(value) {
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

    /// A name is a hint for diagnostics, never proof of the bytes served.
    /// Known preview and encrypted names are rejected conservatively.
    static func fileKind(for url: URL) -> FileKind? {
        let pathExtension = url.pathExtension.lowercased()
        if undecodableExtensions.contains(pathExtension) {
            return .undecodable
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 4 || name.count >= 16,
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

    /// Do not attempt to play an encrypted QQ resource. For ordinary
    /// container extensions the probe rejects unsupported *bytes*, not names.
    private static let undecodableExtensions: Set<String> = [
        "mgg", "mflac", "mmp4", "mnac", "nac",
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
