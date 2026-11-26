import Foundation

struct PlaybackSource: Equatable, Sendable {
    let url: URL
    let bitrate: Int?
    let format: String?
    let quality: MusicQuality?
    let headers: [String: String]
    let sourceName: String?
    let qualityVerified: Bool
    /// Only LX sources carry provenance. The tier asked of the script may
    /// differ from `quality`, which describes the bytes it actually served.
    let sourceID: UUID?
    let requestedQuality: MusicQuality?
    let configurationRevision: UInt64?

    init(
        url: URL,
        bitrate: Int?,
        format: String?,
        quality: MusicQuality? = nil,
        headers: [String: String] = [:],
        sourceName: String? = nil,
        qualityVerified: Bool = true,
        sourceID: UUID? = nil,
        requestedQuality: MusicQuality? = nil,
        configurationRevision: UInt64? = nil
    ) {
        self.url = url
        self.bitrate = bitrate
        self.format = format
        self.quality = quality
        self.headers = headers
        self.sourceName = sourceName
        self.qualityVerified = qualityVerified
        self.sourceID = sourceID
        self.requestedQuality = requestedQuality
        self.configurationRevision = configurationRevision
    }

    var preferredForwardBufferDuration: TimeInterval {
        guard !url.isFileURL else { return 0 }
        if quality?.prefersExtendedBuffering == true
            || (bitrate ?? 0) >= 1_000_000 {
            return 16
        }
        return 8
    }
}
