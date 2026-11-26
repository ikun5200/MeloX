import Foundation
import Observation

nonisolated enum LXPlaybackError: LocalizedError, Sendable {
    case missingSongMID
    case noSource
    case invalidURL
    case noSourceResolved(String?)
    case unplayableStream(String)
    case trialClip

    var errorDescription: String? {
        switch self {
        case .missingSongMID: "这首歌缺少 QQ 音乐 songmid，无法解析播放地址。"
        case .noSource: "没有启用任何支持 QQ 音乐的洛雪源。"
        case .invalidURL: "洛雪源返回了无效的播放地址。"
        case .noSourceResolved(let message):
            if let message { "所有洛雪源都无法解析播放地址：\(message)" }
            else { "所有洛雪源都无法解析播放地址。" }
        case .unplayableStream(let reason): "洛雪源返回的播放地址无法播放（\(reason)）。"
        case .trialClip: "洛雪源只返回了试听片段。"
        }
    }
}

nonisolated enum LXQualityEvidence: Equatable, Sendable {
    case untested, verified, unavailable
}

@MainActor
@Observable
final class LXPlaybackResolver {
    private struct SongTier: Hashable {
        let mid: String
        let tier: MusicQuality
    }
    private struct Attempt: Hashable {
        let source: UUID
        let key: SongTier
    }
    private struct Resource: Hashable {
        let source: UUID
        let address: URL

        init(_ source: UUID, _ url: URL) {
            self.source = source
            // Signed variants of the same media path are not a new grant.
            // This key is private bookkeeping; it is never sent or logged.
            self.address = LXScriptRuntime.resourceAddress(url)
        }
    }
    private struct ReadySource {
        let runtime: LXScriptRuntime
        let qualities: [String]
    }
    private struct CachedSource {
        let source: PlaybackSource
        let expires: Date
    }
    private struct Witness {
        let attempt: Attempt
        let media: Resource
    }
    private struct Finding {
        let witness: Witness? // nil only after a conclusive, exhaustive search
        let sampled: Date
        let expires: Date
    }
    private struct Search {
        let started = Date()
        var candidates: [PlaybackSource] = []
        var exhausted: Set<MusicQuality> = []
    }

    private let store: LXSourceStore
    private let session: URLSession
    private let evidenceLifetime: TimeInterval
    private let failureLifetime: TimeInterval = 300
    private let urlLifetime: TimeInterval = 240
    private var invalidations: UInt64 = 0
    private var findings: [SongTier: Finding] = [:]
    @ObservationIgnored private var preparedRevision: UInt64?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var runtimes: [UUID: ReadySource] = [:]
    @ObservationIgnored private var deniedInitializations: Set<UUID> = []
    @ObservationIgnored private var urls: [SongTier: CachedSource] = [:]
    @ObservationIgnored private var failedAttempts: [Attempt: Date] = [:]
    @ObservationIgnored private var failedMedia: [Resource: Date] = [:]
    @ObservationIgnored private var deniedAttempts: Set<Attempt> = []
    @ObservationIgnored private var deniedMedia: Set<Resource> = []

    init(store: LXSourceStore, session: URLSession = .shared, evidenceLifetime: TimeInterval = 120) {
        self.store = store
        self.session = session
        self.evidenceLifetime = evidenceLifetime
    }

    var configurationRevision: UInt64 { store.configurationRevision &+ invalidations }

    func evidence(for song: Song, quality: MusicQuality) -> LXQualityEvidence {
        let key = SongTier(mid: song.mid.trimmingCharacters(in: .whitespacesAndNewlines), tier: quality)
        let revision = configurationRevision
        let finding = findings[key] // Subscribe even before the very first resolve.
        guard revision == preparedRevision, let finding,
              finding.expires > Date() else { return .untested }
        return finding.witness == nil ? .unavailable : .verified
    }

    var supportedQualities: [MusicQuality] {
        let sources = store.enabledQQSources
        return MusicQuality.allCases.filter { tier in
            sources.contains { !LXQualityMapping.sourceNames(for: tier, declared: $0.qqQualities).isEmpty }
        }
    }

    func resolve(
        song: Song,
        quality: MusicQuality,
        availability: SongAudioAvailability = .unknown,
        bypassingCache: Bool = false
    ) async throws -> PlaybackSource {
        try Task.checkCancellation()
        let mid = song.mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { throw LXPlaybackError.missingSongMID }
        let revision = prepareConfiguration()
        let sources = store.enabledQQSources
        guard !sources.isEmpty else { throw LXPlaybackError.noSource }
        let key = SongTier(mid: mid, tier: quality)
        let now = Date()
        urls = urls.filter { $0.value.expires > now }
        failedAttempts = failedAttempts.filter { $0.value > now }
        failedMedia = failedMedia.filter { $0.value > now }
        if bypassingCache { urls[key] = nil }
        if let cached = urls[key]?.source, canUse(cached, mid: mid),
           sources.contains(where: { $0.id == cached.sourceID }) {
            try check(revision)
            return cached
        }

        let catalog = availability.isKnown ? availability : song.audioAvailability
        let duration = Double(max(0, song.durationMS)) / 1_000
        let info = musicInfo(for: song)
        var search = Search()
        var timedOut: Set<UUID> = []
        var offline: Set<UUID> = []
        // QQ's catalog is byte-size corroboration, not a list of the grants
        // held by independently configured musicUrl sources.
        for tier in LXQualityMapping.ladder(from: quality) {
            var tried = false
            var conclusive = true
            for source in sources {
                try check(revision)
                let names = LXQualityMapping.sourceNames(for: tier, declared: source.qqQualities)
                guard !names.isEmpty else { continue }
                let attempt = Attempt(source: source.id, key: SongTier(mid: mid, tier: tier))
                if deniedAttempts.contains(attempt) || deniedInitializations.contains(source.id) {
                    tried = true
                    continue
                }
                if offline.contains(source.id) || failedAttempts[attempt] != nil {
                    conclusive = false
                    continue
                }

                let ready: ReadySource
                do { ready = try await runtime(for: source, revision: revision) }
                catch {
                    try check(revision)
                    if error is CancellationError { throw CancellationError() }
                    if case LXScriptError.httpStatus(let code) = error, [401, 402, 403].contains(code) {
                        tried = true
                        deniedInitializations.insert(source.id)
                    } else {
                        offline.insert(source.id)
                        conclusive = false
                    }
                    rigTrace("resolver", "event=init_failed source=\(source.id)")
                    continue
                }
                let liveNames = LXQualityMapping.sourceNames(for: tier, declared: ready.qualities)
                for name in names where liveNames.contains(name) {
                    tried = true
                    var media: Resource?
                    do {
                        try check(revision)
                        let value = try await ready.runtime.resolveMusicURL(
                            musicInfo: info, quality: name, timeout: timedOut.contains(source.id) ? 5 : 15
                        )
                        try check(revision)
                        guard let url = secureURL(value) else { throw LXPlaybackError.invalidURL }
                        let resource = Resource(source.id, url)
                        media = resource
                        if deniedAttempts.contains(attempt) || deniedMedia.contains(resource) { break }
                        if failedMedia[resource] != nil {
                            conclusive = false
                            continue
                        }
                        let fileKind = LXQualityMapping.fileKind(for: url)
                        if fileKind == .trialClip { throw LXPlaybackError.trialClip }
                        if fileKind == .undecodable { throw LXPlaybackError.unplayableStream("不支持的格式") }
                        let probe = try await LXStreamProbe.run(url, session: session)
                        try check(revision)
                        let verdict = try Self.assess(probe, availability: catalog, duration: duration)
                        let stream = PlaybackSource(
                            url: url, bitrate: probe.nominalBitrate ?? LXQualityMapping.bitrate(for: verdict.quality),
                            format: probe.container.format, quality: verdict.quality, sourceName: source.name,
                            qualityVerified: verdict.verified, sourceID: source.id, requestedQuality: tier,
                            configurationRevision: revision
                        )
                        guard canUse(stream, mid: mid) else { conclusive = false; break }
                        let named: MusicQuality? = if case .tier(let value) = fileKind { value } else { nil }
                        let ext = url.pathExtension.lowercased()
                        let expectedFormat = ["mp4": "m4a", "mpeg": "mp3", "wave": "wav"][ext] ?? ext
                        let wrongExtension = ["flac", "mp3", "m4a", "aac", "wav", "ogg"].contains(expectedFormat)
                            && expectedFormat != probe.container.format
                        rigTrace("resolver", "event=probe source=\(source.id) asked=\(tier.rawValue) actual=\(verdict.quality.rawValue)"
                            + " container=\(probe.container.rawValue) size=\(probe.length ?? -1) rate=\(probe.flac?.sampleRate ?? 0)"
                            + " bits=\(probe.flac?.bitsPerSample ?? 0) rule=\(verdict.rule.rawValue) verified=\(verdict.verified)"
                            + " mimeMismatch=\(probe.mimeMismatch) extensionMismatch=\(wrongExtension)"
                            + " nameMismatch=\(named.map { $0 != verdict.quality } ?? false)")
                        search.candidates.append(stream)
                        if verdict.verified, Self.honours(stream, tier: tier, preference: quality) {
                            return try finish(search, mid: mid, preference: quality, revision: revision)
                        }
                        if !verdict.rulesOut(tier, lossless: probe.isLossless) { conclusive = false }
                    } catch {
                        try check(revision)
                        if error is CancellationError || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        let failure = Self.failure(error, name: name)
                        rigTrace("resolver", "event=rejected source=\(source.id) asked=\(tier.rawValue) reason=\(failure.rawValue)")
                        switch failure {
                        case .denied:
                            deny(attempt, media: media)
                        case .timeout:
                            conclusive = false
                            timedOut.insert(source.id)
                        case .indeterminate:
                            conclusive = false
                        case .noMatch:
                            continue // A distinct declared alias may still work.
                        }
                        break // No alias retry after a denial or a transient failure.
                    }
                }
            }
            if tried && conclusive { search.exhausted.insert(tier) }
            // An estimate waits through *its own* tier's other sources. A
            // lower-tier result can never jump ahead of an untried higher tier.
            if let best = best(in: search, mid: mid, preference: quality),
               Self.honours(best, tier: tier, preference: quality) { break }
        }
        return try finish(search, mid: mid, preference: quality, revision: revision)
    }

    private enum Rule: String { case streamInfo, catalogAndAudio, estimate }
    private struct Verdict {
        let quality: MusicQuality
        let rule: Rule
        var verified: Bool { rule != .estimate }

        func rulesOut(_ requested: MusicQuality, lossless: Bool) -> Bool {
            guard quality != requested else { return false }
            if rule == .catalogAndAudio { return true }
            let wantsLossy = requested == .standard || requested == .high
            if lossless == wantsLossy { return true } // Incompatible container.
            switch requested {
            case .ultraClearMaster, .highDefinitionSurround, .immersiveSurround:
                // Technical resolution alone neither proves nor disproves a branded mix.
                return false
            default: return verified
            }
        }
    }

    private static func assess(_ probe: LXStreamProbe, availability: SongAudioAvailability,
                               duration: TimeInterval) throws -> Verdict {
        let sized = MusicQuality.allCases.filter { tier in
            guard let size = availability.fileSize(of: tier) else { return false }
            return size == probe.length
        }
        let match = sized.count == 1 ? sized.first : nil
        let timed = duration > 0 && probe.duration != nil
        if duration > 0, let seconds = probe.duration {
            let tolerance = max(1.5, min(4, duration * 0.02))
            if seconds < duration - tolerance { throw LXPlaybackError.trialClip }
            if seconds > duration + tolerance { throw LXPlaybackError.unplayableStream("时长不符") }
        }
        let complete = timed && probe.length != nil
        if let flac = probe.flac {
            // A branded encoding is not a PCM resolution. In particular a
            // genuine stereo Q000 can be 44.1 kHz / 16-bit. Identify it by
            // the catalog's unique byte count plus a compatible full track.
            if complete, let match {
                switch match {
                case .ultraClearMaster:
                    return Verdict(quality: match, rule: .catalogAndAudio)
                case .highDefinitionSurround, .immersiveSurround:
                    if flac.channelCount == 2 { return Verdict(quality: match, rule: .catalogAndAudio) }
                default: break
                }
            }
            let cdGrade = flac.bitsPerSample >= 16 && flac.sampleRate >= 44_100
            guard cdGrade else { return Verdict(quality: .standard, rule: .estimate) }
            let hiRes = flac.bitsPerSample >= 24 && flac.sampleRate >= 88_200
            let actual: MusicQuality = hiRes ? .hiResolution : .lossless
            let rule: Rule = !complete ? .estimate : (match == actual ? .catalogAndAudio : .streamInfo)
            return Verdict(quality: actual, rule: rule)
        }
        let average = probe.length.flatMap { duration > 0 ? Double($0) * 8 / duration : nil }
        if !timed, let size = probe.length {
            let small = availability.smallestFileSize.map { Double(size) < Double($0) * 0.6 } ?? false
            if small || (duration >= 100 && (average ?? .infinity) < 64_000) { throw LXPlaybackError.trialClip }
            if !probe.isLossless, duration >= 30, let nominal = probe.nominalBitrate,
               let average, average < Double(nominal) * 0.6 { throw LXPlaybackError.trialClip }
        }
        if probe.isLossless { return Verdict(quality: .lossless, rule: .estimate) }
        let lossy: MusicQuality = (average ?? Double(probe.nominalBitrate ?? 0)) >= 250_000 ? .high : .standard
        // A size collision with a FLAC entry cannot turn MP3 into FLAC.
        return Verdict(quality: lossy, rule: complete && match == lossy ? .catalogAndAudio : .estimate)
    }

    private enum Failure: String { case noMatch, denied, timeout, indeterminate }
    private static func failure(_ error: Error, name: String) -> Failure {
        func status(_ code: Int) -> Failure {
            switch code {
            case 401, 402, 403: .denied
            case 404, 410: .noMatch
            case 408, 504: .timeout
            default: .indeterminate // Includes 429, 5xx, and transport failures.
            }
        }
        if let http = error as? LXStreamProbe.HTTPFailure { return status(http.status) }
        if let runtime = error as? LXScriptError {
            switch runtime {
            case .httpStatus(let code): return status(code)
            case .requestTimedOut, .initializationTimedOut: return .timeout
            case .javaScript(let text):
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // Some scripts reject directly, without a native HTTP call.
                // Never expose their text or infer absence from a generic error.
                if ["unauthorized", "forbidden", "payment required", "未获授权", "无权限"].contains(message)
                    || message.range(of: #"\b(401|402|403)\b"#, options: .regularExpression) != nil { return .denied }
                if ["unsupported quality", "unsupported quality \(name)", "quality not supported",
                    "no \(name) for this song"].contains(message) { return .noMatch }
                return .indeterminate
            case .invalidURL: return .noMatch
            default: return .indeterminate
            }
        }
        if error is LXPlaybackError { return .noMatch }
        return (error as? URLError)?.code == .timedOut ? .timeout : .indeterminate
    }

    // MARK: - Evidence, URL reuse and failure avoidance

    private func check(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard configurationRevision == revision else { throw CancellationError() }
    }

    private func prepareConfiguration() -> UInt64 {
        let revision = configurationRevision
        if preparedRevision != revision {
            runtimes.values.forEach { $0.runtime.shutdown() }
            runtimes.removeAll()
            deniedInitializations.removeAll()
            urls.removeAll()
            failedAttempts.removeAll()
            failedMedia.removeAll()
            deniedAttempts.removeAll()
            deniedMedia.removeAll()
            findings.removeAll()
            expiryTask?.cancel()
            expiryTask = nil
            preparedRevision = revision
        }
        return revision
    }

    private func canUse(_ stream: PlaybackSource, mid: String) -> Bool {
        guard stream.configurationRevision == configurationRevision,
              let id = stream.sourceID, let asked = stream.requestedQuality else { return false }
        let attempt = Attempt(source: id, key: SongTier(mid: mid, tier: asked))
        let media = Resource(id, stream.url)
        guard let actual = stream.quality else { return false }
        let actualAttempt = Attempt(source: id, key: SongTier(mid: mid, tier: actual))
        return !deniedAttempts.contains(attempt) && !deniedAttempts.contains(actualAttempt)
            && !deniedMedia.contains(media) && failedAttempts[attempt] == nil && failedMedia[media] == nil
    }

    private func deny(_ attempt: Attempt, media: Resource?) {
        deniedAttempts.insert(attempt)
        if let media { deniedMedia.insert(media) }
        urls = urls.filter { canUse($0.value.source, mid: $0.key.mid) }
        findings = findings.filter { key, finding in
            guard let witness = finding.witness else { return true }
            return witness.attempt != attempt && witness.media != media
                && !(witness.attempt.source == attempt.source && key == attempt.key)
        }
    }

    private func best(in search: Search, mid: String, preference: MusicQuality) -> PlaybackSource? {
        let limit = LXQualityMapping.rank(of: preference)
        func score(_ stream: PlaybackSource) -> (Int, Bool) {
            let rank = LXQualityMapping.rank(of: stream.quality)
            return (rank <= limit ? rank : -rank - 1, stream.qualityVerified)
        }
        return search.candidates.filter { canUse($0, mid: mid) }.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            let lhs = score(candidate), rhs = score(current)
            return lhs.0 > rhs.0 || (lhs.0 == rhs.0 && lhs.1 && !rhs.1) ? candidate : current
        }
    }

    private static func honours(_ stream: PlaybackSource, tier: MusicQuality, preference: MusicQuality) -> Bool {
        let rank = LXQualityMapping.rank(of: stream.quality)
        return rank >= LXQualityMapping.rank(of: tier) && rank <= LXQualityMapping.rank(of: preference)
    }

    private func finish(_ search: Search, mid: String, preference: MusicQuality, revision: UInt64) throws -> PlaybackSource {
        // No await between validation, publication of evidence and return.
        try check(revision)
        let now = Date()
        let expiry = now.addingTimeInterval(evidenceLifetime)
        for tier in search.exhausted {
            let key = SongTier(mid: mid, tier: tier)
            // Do not overwrite a positive observation published by a newer,
            // overlapping search; an explicit fresh search can disprove an old hit.
            if let found = findings[key], found.witness != nil, found.sampled > search.started { continue }
            findings[key] = Finding(witness: nil, sampled: now, expires: expiry)
            urls[key] = nil
        }
        for stream in search.candidates where canUse(stream, mid: mid) {
            guard let actual = stream.quality, let id = stream.sourceID, let asked = stream.requestedQuality else { continue }
            let askedKey = SongTier(mid: mid, tier: asked)
            let witness = Witness(attempt: Attempt(source: id, key: askedKey), media: Resource(id, stream.url))
            if (actual != asked || !stream.qualityVerified), let old = findings[askedKey],
               old.sampled < search.started, old.witness?.attempt == witness.attempt {
                findings[askedKey] = nil
                urls[askedKey] = nil
            }
            if stream.qualityVerified {
                findings[SongTier(mid: mid, tier: actual)] = Finding(witness: witness, sampled: now, expires: expiry)
            }
        }
        scheduleExpiry()
        guard let source = best(in: search, mid: mid, preference: preference) else {
            throw LXPlaybackError.noSourceResolved(nil)
        }
        // Never cache an estimate/downgrade as a hit for the user's higher
        // preference. A transiently absent better source must get another turn.
        if source.qualityVerified, let actual = source.quality {
            urls[SongTier(mid: mid, tier: actual)] = CachedSource(
                source: source, expires: min(expiry, now.addingTimeInterval(urlLifetime))
            )
        }
        return source
    }

    private func scheduleExpiry() {
        guard expiryTask == nil, let first = findings.values.map(\.expires).min() else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, first.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            self.expiryTask = nil
            self.findings = self.findings.filter { $0.value.expires > Date() }
            self.scheduleExpiry()
        }
    }

    func reportUnplayable(_ source: PlaybackSource, for song: Song) {
        let revision = prepareConfiguration()
        let mid = song.mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty, source.configurationRevision == revision,
              let id = source.sourceID, let asked = source.requestedQuality else { return }
        let until = Date().addingTimeInterval(failureLifetime)
        failedAttempts[Attempt(source: id, key: SongTier(mid: mid, tier: asked))] = until
        failedMedia[Resource(id, source.url)] = until
        urls = urls.filter { canUse($0.value.source, mid: $0.key.mid) }
        if let actual = source.quality {
            let key = SongTier(mid: mid, tier: actual)
            if findings[key]?.witness?.media == Resource(id, source.url) { findings[key] = nil }
        }
    }

    func invalidate(sourceID: UUID? = nil) {
        invalidations &+= 1
        _ = prepareConfiguration()
    }

    func shutdown() { invalidate() }

    private func runtime(for source: LXSource, revision: UInt64) async throws -> ReadySource {
        if let existing = runtimes[source.id] { return existing }
        let runtime = LXScriptRuntime(preload: try store.loadPreload(), session: session)
        do {
            let descriptor = try await runtime.initialize(script: source.rawScript, info: LXScriptInfo(
                name: source.name, description: "", version: source.version, author: source.author,
                homepage: source.homepage, rawScript: source.rawScript
            ))
            try check(revision)
            guard let live = descriptor.qqSource else { throw LXSourceError.noQQSource }
            if let existing = runtimes[source.id] {
                runtime.shutdown()
                return existing
            }
            let ready = ReadySource(runtime: runtime, qualities: live.qualitys)
            runtimes[source.id] = ready
            return ready
        } catch {
            runtime.shutdown()
            throw error
        }
    }

    private func musicInfo(for song: Song) -> [String: Any] {
        var info: [String: Any] = [
            "source": "tx", "songmid": song.mid, "id": song.id, "name": song.name,
            "singer": song.artistText, "albumName": song.album?.name ?? "",
            "interval": max(song.durationMS / 1_000, 0),
        ]
        if let mediaMID = song.mediaMID, !mediaMID.isEmpty {
            info["media_mid"] = mediaMID
            info["strMediaMid"] = mediaMID
        }
        if let album = song.album { info["albumId"] = album.id; info["albumMid"] = album.mid }
        if let mvID = song.musicVideoID { info["mvid"] = mvID }
        if let mvMID = song.musicVideoMID { info["vid"] = mvMID }
        return info
    }

    private func secureURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.host?.isEmpty == false else { return nil }
        if url.scheme?.lowercased() == "https" { return url }
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }
}
