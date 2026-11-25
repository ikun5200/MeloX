import Foundation

nonisolated enum LXPlaybackError: LocalizedError, Sendable {
    case missingSongMID
    case noSource
    case invalidURL
    case noSourceResolved(String?)
    /// The address a source returned does not serve the song.
    case unplayableStream(String)
    /// QQ's short preview clip, returned in place of the song.
    case trialClip

    var errorDescription: String? {
        switch self {
        case .missingSongMID:
            "这首歌缺少 QQ 音乐 songmid，无法解析播放地址。"
        case .noSource:
            "没有启用任何支持 QQ 音乐的洛雪源。"
        case .invalidURL:
            "洛雪源返回了无效的播放地址。"
        case .noSourceResolved(let message):
            if let message, !message.isEmpty {
                "所有洛雪源都无法解析播放地址：\(message)"
            } else {
                "所有洛雪源都无法解析播放地址。"
            }
        case .unplayableStream(let reason):
            "洛雪源返回的播放地址无法播放（\(reason)）。"
        case .trialClip:
            "洛雪源只返回了试听片段。"
        }
    }
}

/// 按优先级依次调用已启用的洛雪源，把 QQ 歌曲解析成可播放 URL。
///
/// 所选音质是长期偏好。歌曲没有这一档、或没有源能给出这一档时，
/// 按 QQ 的档位顺序逐档下降，直到拿到一个确实能播放的地址。
@MainActor
final class LXPlaybackResolver {
    private struct CachedSource {
        let source: PlaybackSource
        let date: Date
    }

    /// What a returned address turned out to serve.
    private struct Verdict {
        let quality: MusicQuality
        let isVerified: Bool
    }

    private let store: LXSourceStore
    private let session: URLSession
    private let cacheLifetime: TimeInterval = 240
    /// How long a stream the player could not play is left alone.
    private let failureLifetime: TimeInterval = 300
    /// How long a source is given to answer, and how long once it has
    /// already failed to: one that hangs on a single tier may still answer
    /// the next, but is not worth a second full wait.
    private let requestTimeout: TimeInterval = 15
    private let requestTimeoutAfterTimeout: TimeInterval = 5

    private var runtimes: [UUID: LXScriptRuntime] = [:]
    private var cache: [String: CachedSource] = [:]
    private var failedStreams: [String: Date] = [:]
    private var timedOutSources: [UUID: Date] = [:]

    init(store: LXSourceStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    var supportedQualities: [MusicQuality] {
        let declared = Set(
            store.enabledQQSources.flatMap { $0.qqQualities }
        )
        guard !declared.isEmpty else {
            return MusicQuality.allCases
        }
        let mapped = declared.compactMap {
            LXQualityMapping.quality(for: $0)
        }
        guard !mapped.isEmpty else { return MusicQuality.allCases }
        return MusicQuality.allCases.filter { mapped.contains($0) }
    }

    func resolve(
        song: Song,
        quality: MusicQuality,
        availability: SongAudioAvailability = .unknown,
        bypassingCache: Bool = false
    ) async throws -> PlaybackSource {
        let songMID = song.mid.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !songMID.isEmpty else {
            throw LXPlaybackError.missingSongMID
        }

        let cacheKey = "\(songMID)#\(quality.rawValue)"
        if bypassingCache {
            cache[cacheKey] = nil
            forgetFailures(forSongMID: songMID)
        } else if let cached = cache[cacheKey],
                  Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.source
        }

        let sources = orderedSources()
        guard !sources.isEmpty else {
            throw LXPlaybackError.noSource
        }

        // QQ reports which encodings a song has. A tier it lacks is not
        // asked for: every source would spend a request to say no.
        let ladder = LXQualityMapping.ladder(from: quality)
        var tiers = ladder.filter { availability.supports($0) != false }
        if tiers.isEmpty {
            tiers = ladder
        }

        let musicInfo = musicInfo(for: song)
        let duration = TimeInterval(max(song.durationMS, 0)) / 1_000
        var lastError: Error?
        var unreachableSourceIDs: Set<UUID> = []
        var timedOutSourceIDs: Set<UUID> = []
        // A stream that turned out to be another tier than it was asked as.
        var fallback: PlaybackSource?

        for (tierIndex, tier) in tiers.enumerated() {
            // A tier is offered to every source before stepping down, so a
            // lower-priority source that has it wins over a downgrade.
            for source in sources
            where !unreachableSourceIDs.contains(source.id) {
                try Task.checkCancellation()
                let names = LXQualityMapping.sourceNames(
                    for: tier,
                    declared: source.qqQualities
                )
                guard !names.isEmpty,
                      !hasFailed(songMID: songMID, tier, source.name) else {
                    continue
                }

                let scriptRuntime: LXScriptRuntime
                do {
                    scriptRuntime = try await runtime(for: source)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    unreachableSourceIDs.insert(source.id)
                    runtimes[source.id] = nil
                    store.updateAfterRuntimeFailure(source, error: error)
                    continue
                }

                for name in names {
                    do {
                        let rawURL = try await scriptRuntime.resolveMusicURL(
                            musicInfo: musicInfo,
                            quality: name,
                            timeout: timedOutSourceIDs.contains(source.id)
                                ? requestTimeoutAfterTimeout
                                : requestTimeout
                        )
                        guard let url = secureURL(rawURL) else {
                            throw LXPlaybackError.invalidURL
                        }
                        let verdict = try await verify(
                            url,
                            requestedAs: tier,
                            availability: availability,
                            duration: duration
                        )
                        let stream = PlaybackSource(
                            url: url,
                            bitrate: LXQualityMapping.bitrate(
                                for: verdict.quality
                            ),
                            format: LXQualityMapping.format(
                                for: url,
                                quality: verdict.quality
                            ),
                            quality: verdict.quality,
                            headers: [:],
                            sourceName: source.name,
                            qualityVerified: verdict.isVerified
                        )
                        if Self.honours(
                            stream,
                            tier: tier,
                            preference: quality
                        ) {
                            return remember(stream, for: cacheKey)
                        }
                        if Self.isBetter(
                            stream,
                            than: fallback,
                            preference: quality
                        ) {
                            fallback = stream
                        }
                        // The source's other name for this tier would be
                        // answered with the same file.
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch LXScriptError.requestTimedOut {
                        lastError = LXScriptError.requestTimedOut
                        timedOutSources[source.id] = Date()
                        if !timedOutSourceIDs.insert(source.id).inserted {
                            unreachableSourceIDs.insert(source.id)
                        }
                        break
                    } catch {
                        lastError = error
                    }
                }
            }

            // A stream already in hand that is no worse than the next tier
            // down makes asking for that tier pointless.
            if let fallback,
               LXQualityMapping.rank(of: fallback.quality)
                <= LXQualityMapping.rank(of: quality) {
                let nextTier = tiers.indices.contains(tierIndex + 1)
                    ? tiers[tierIndex + 1]
                    : nil
                if LXQualityMapping.rank(of: fallback.quality)
                    >= LXQualityMapping.rank(of: nextTier) {
                    return remember(fallback, for: cacheKey)
                }
            }
        }

        if let fallback {
            return remember(fallback, for: cacheKey)
        }
        throw LXPlaybackError.noSourceResolved(
            lastError?.localizedDescription
        )
    }

    /// Records that the player could not play `source`, so the next
    /// resolution moves on to another source or the next tier down instead
    /// of returning the same address.
    func reportUnplayable(_ source: PlaybackSource, for song: Song) {
        let songMID = song.mid.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !songMID.isEmpty else { return }
        cache = cache.filter { $0.value.source.url != source.url }
        guard let quality = source.quality,
              let sourceName = source.sourceName else {
            return
        }
        failedStreams[
            failureKey(songMID: songMID, quality, sourceName)
        ] = Date()
    }

    func invalidate(sourceID: UUID? = nil) {
        if let sourceID {
            runtimes[sourceID]?.shutdown()
            runtimes[sourceID] = nil
            timedOutSources[sourceID] = nil
        } else {
            runtimes.values.forEach { $0.shutdown() }
            runtimes.removeAll()
            timedOutSources.removeAll()
        }
        cache.removeAll()
        failedStreams.removeAll()
    }

    func shutdown() {
        invalidate()
    }

    // MARK: - Verification

    private func verify(
        _ url: URL,
        requestedAs tier: MusicQuality,
        availability: SongAudioAvailability,
        duration: TimeInterval
    ) async throws -> Verdict {
        let fileKind = LXQualityMapping.fileKind(for: url)
        switch fileKind {
        case .trialClip:
            throw LXPlaybackError.trialClip
        case .undecodable:
            throw LXPlaybackError.unplayableStream(
                url.pathExtension.lowercased()
            )
        case .tier, nil:
            break
        }

        let probe: LXStreamProbe
        do {
            probe = try await LXStreamProbe.run(url, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LXPlaybackError {
            throw error
        } catch {
            throw LXPlaybackError.unplayableStream(
                error.localizedDescription
            )
        }

        if let length = probe.length {
            if let matched = availability.quality(ofFileSized: length) {
                return Verdict(quality: matched, isVerified: true)
            }
            if Self.isTruncated(
                length: length,
                availability: availability,
                duration: duration
            ) {
                throw LXPlaybackError.trialClip
            }
        }
        if case .tier(let named) = fileKind {
            return Verdict(quality: named, isVerified: true)
        }
        return Verdict(
            quality: Self.estimatedQuality(
                of: url,
                probe: probe,
                requestedAs: tier,
                duration: duration
            ),
            isVerified: false
        )
    }

    /// A file far smaller than the song's smallest encoding is a preview
    /// clip or a cut-off transfer, not the song.
    private static func isTruncated(
        length: Int64,
        availability: SongAudioAvailability,
        duration: TimeInterval
    ) -> Bool {
        if let smallest = availability.smallestFileSize {
            return Double(length) < Double(smallest) * 0.6
        }
        // Without sizes to compare with, only the average bitrate is left,
        // and it tells nothing for a song about as short as a clip.
        guard duration >= 100 else { return false }
        return Double(length) * 8 / duration < 64_000
    }

    /// The tier of a stream nothing identifies: no file size to match, no
    /// QQ file name. The container tells a lossy file from a lossless one,
    /// and the average bitrate tells the rest where QQ's tiers do not
    /// overlap: its masters run above 4.5 Mbps and its Hi-Res files near
    /// 3, while plain FLAC stays under 2. The surround tiers overlap with
    /// FLAC and are taken at their word.
    private static func estimatedQuality(
        of url: URL,
        probe: LXStreamProbe,
        requestedAs tier: MusicQuality,
        duration: TimeInterval
    ) -> MusicQuality {
        let lossyExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4"]
        let lossyTypes: Set<String> = [
            "audio/mpeg", "audio/mp3", "audio/aac", "audio/aacp",
            "audio/mp4", "audio/m4a", "audio/x-m4a",
        ]
        let isLossy = lossyExtensions.contains(
            url.pathExtension.lowercased()
        ) || probe.contentType.map(lossyTypes.contains) == true

        guard let length = probe.length, duration >= 30 else {
            let isAboveLossy = LXQualityMapping.rank(of: tier)
                > LXQualityMapping.rank(of: .high)
            return isLossy && isAboveLossy ? .high : tier
        }
        let bitrate = Double(length) * 8 / duration
        if isLossy {
            return bitrate >= 250_000 ? .high : .standard
        }
        switch tier {
        case .ultraClearMaster where bitrate < 4_000_000:
            return bitrate >= 2_300_000 ? .hiResolution : .lossless
        case .hiResolution where bitrate < 2_300_000:
            return .lossless
        default:
            return tier
        }
    }

    /// Whether a stream answers the tier it was asked as: that tier itself,
    /// or something better that the listener's choice still allows.
    private static func honours(
        _ stream: PlaybackSource,
        tier: MusicQuality,
        preference: MusicQuality
    ) -> Bool {
        let rank = LXQualityMapping.rank(of: stream.quality)
        return rank >= LXQualityMapping.rank(of: tier)
            && rank <= LXQualityMapping.rank(of: preference)
    }

    /// The best stand-in is the highest tier within the listener's choice.
    /// One above the choice only serves when nothing else plays, and then
    /// the nearest is the least wasteful.
    private static func isBetter(
        _ stream: PlaybackSource,
        than current: PlaybackSource?,
        preference: MusicQuality
    ) -> Bool {
        guard let current else { return true }
        let limit = LXQualityMapping.rank(of: preference)
        let rank = LXQualityMapping.rank(of: stream.quality)
        let currentRank = LXQualityMapping.rank(of: current.quality)
        switch (rank <= limit, currentRank <= limit) {
        case (true, true): return rank > currentRank
        case (true, false): return true
        case (false, true): return false
        case (false, false): return rank < currentRank
        }
    }

    // MARK: - Bookkeeping

    private func remember(
        _ source: PlaybackSource,
        for cacheKey: String
    ) -> PlaybackSource {
        cache[cacheKey] = CachedSource(source: source, date: Date())
        return source
    }

    /// Sources in priority order, with any that recently timed out moved
    /// to the back so the next song does not wait on them again.
    private func orderedSources() -> [LXSource] {
        let now = Date()
        timedOutSources = timedOutSources.filter {
            now.timeIntervalSince($0.value) < failureLifetime
        }
        let sources = store.enabledQQSources
        return sources.filter { timedOutSources[$0.id] == nil }
            + sources.filter { timedOutSources[$0.id] != nil }
    }

    private func failureKey(
        songMID: String,
        _ quality: MusicQuality,
        _ sourceName: String
    ) -> String {
        "\(songMID)#\(quality.rawValue)#\(sourceName)"
    }

    private func hasFailed(
        songMID: String,
        _ quality: MusicQuality,
        _ sourceName: String
    ) -> Bool {
        let key = failureKey(songMID: songMID, quality, sourceName)
        guard let date = failedStreams[key] else { return false }
        if Date().timeIntervalSince(date) < failureLifetime {
            return true
        }
        failedStreams[key] = nil
        return false
    }

    private func forgetFailures(forSongMID songMID: String) {
        failedStreams = failedStreams.filter {
            !$0.key.hasPrefix("\(songMID)#")
        }
    }

    private func runtime(for source: LXSource) async throws -> LXScriptRuntime {
        if let existing = runtimes[source.id] {
            return existing
        }

        let preload = try store.loadPreload()
        let runtime = LXScriptRuntime(
            preload: preload,
            session: session
        )
        do {
            _ = try await runtime.initialize(
                script: source.rawScript,
                info: LXScriptInfo(
                    name: source.name,
                    description: "",
                    version: source.version,
                    author: source.author,
                    homepage: source.homepage,
                    rawScript: source.rawScript
                )
            )
        } catch {
            runtime.shutdown()
            throw error
        }
        runtimes[source.id] = runtime
        return runtime
    }

    private func musicInfo(for song: Song) -> [String: Any] {
        var info: [String: Any] = [
            "source": "tx",
            "songmid": song.mid,
            "id": song.id,
            "name": song.name,
            "singer": song.artistText,
            "albumName": song.album?.name ?? "",
            "interval": max(song.durationMS / 1_000, 0),
        ]
        if let mediaMID = song.mediaMID, !mediaMID.isEmpty {
            info["media_mid"] = mediaMID
            info["strMediaMid"] = mediaMID
        }
        if let album = song.album {
            info["albumId"] = album.id
            info["albumMid"] = album.mid
        }
        if let mvID = song.musicVideoID {
            info["mvid"] = mvID
        }
        if let mvMID = song.musicVideoMID {
            info["vid"] = mvMID
        }
        return info
    }

    private func secureURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let url = components.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
