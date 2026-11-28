@preconcurrency import AVFoundation
@preconcurrency import AudioStreaming

@MainActor
final class AudioPlaybackDeck: NSObject, @preconcurrency AudioPlayerDelegate {
    var onStateChanged: (() -> Void)?
    var onSeekCompleted: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private(set) var state: AudioPlaybackState = .idle
    private(set) var itemIdentifier: Int?
    private(set) var itemID: UUID?
    private(set) var error: Error?
    private(set) var channelCount: AVAudioChannelCount = 2
    /// What the decoder was opened with, for the diagnostics panel.
    private(set) var decodedSampleRate: Double?
    private(set) var decodedIsInterleaved: Bool?
    private var player: AudioStreaming.AudioPlayer?
    private var formatTask: Task<Void, Never>?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var source: PlaybackSource?
    private var finishedPosition: TimeInterval?
    private var currentEntryID: AudioEntryId?
    private var initialSeek: TimeInterval?
    private var isSeeking = false
    private var wantsPlayback = false
    private var playbackRate: Float = 1
    private var outputVolume: Float = 1
    private let equalizer: AudioEqualizerProcessor

    #if os(iOS)
    private let spectrum = SharedPlaybackAudioSpectrum()
    var spectrumSnapshot: PlaybackAudioSpectrumSnapshot { spectrum.snapshot() }
    #endif

    init(equalizerConfiguration: AudioEqualizerConfiguration) {
        equalizer = AudioEqualizerProcessor(configuration: equalizerConfiguration)
    }

    var hasCurrentItem: Bool { itemID != nil }
    var isReady: Bool { state == .playing || state == .paused }
    /// Unlike `isReady`, excludes an ended/failed item and a pause during loading.
    var isPrerolled: Bool {
        state == .paused && player?.state == .paused && currentEntryID != nil
            && !isSeeking && initialSeek == nil && finishedPosition == nil && error == nil
    }
    var currentPlaybackTime: TimeInterval? {
        guard let player, !isSeeking, initialSeek == nil else { return nil }
        return finishedPosition ?? max(player.progress, 0)
    }
    var playbackDuration: TimeInterval? {
        guard let duration = player?.duration, duration > 0 else { return nil }
        return duration
    }
    var rate: Float {
        get { state == .playing ? playbackRate : 0 }
        set {
            if newValue == 0 { pause() }
            else {
                playbackRate = newValue
                player?.rate = newValue
                play()
            }
        }
    }
    var volume: Float {
        get { outputVolume }
        set {
            outputVolume = newValue
            if isReady { player?.volume = newValue }
        }
    }

    func load(_ source: PlaybackSource, itemID id: UUID = UUID(), identifier: Int? = nil,
              startAt: TimeInterval = 0, autoplay: Bool = false, timeout: Duration? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        clear()
        itemID = id
        itemIdentifier = identifier
        self.source = source
        wantsPlayback = autoplay
        initialSeek = max(startAt, 0)
        isSeeking = true
        transition(to: .loading)

        // Own the wait from before the format probe through the first decoded seek.
        // clear() must release it even if the asset probe or the decoder never replies.
        let deadline = timeout.map { timeout in
            Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.cancelLoad(id: id)
            }
        }
        defer { deadline?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard itemID == id, !Task.isCancelled else {
                    if itemID == id { clear() }
                    continuation.resume(returning: false)
                    return
                }
                loadContinuation = continuation
                formatTask = Task { @MainActor [weak self] in
                    let format = await AudioPlaybackFormat.load(from: source.url, headers: source.headers)
                    guard let self, self.itemID == id, !Task.isCancelled else { return }
                    self.formatTask = nil
                    self.startDecoder(source, format: format)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelLoad(id: id) }
        }
    }

    private func cancelLoad(id: UUID) {
        guard itemID == id, loadContinuation != nil else { return }
        clear()
    }

    private func startDecoder(_ source: PlaybackSource, format: AVAudioFormat?) {
        let player = AudioStreaming.AudioPlayer(
            configuration: AudioPlayerConfiguration(
                bufferSizeInSeconds: max(source.preferredForwardBufferDuration, 8),
                secondsRequiredToStartPlaying: 0.3, gracePeriodAfterSeekInSeconds: 0.1,
                // 欠载后多攒几秒再恢复：吞吐贴地飞行时 1 秒会立刻再饿，
                // 反复欠载听起来就像低倍速、掉帧。
                secondsRequiredToStartPlayingAfterBufferUnderrun: 3),
            outputFormat: format)
        self.player = player
        channelCount = format?.channelCount ?? 2
        decodedSampleRate = format?.sampleRate
        decodedIsInterleaved = format?.isInterleaved
        player.volume = 0
        player.delegate = self
        equalizer.attach(to: player)
        #if os(iOS)
        let analyzer = PlaybackAudioSpectrumAnalyzer(sharedSpectrum: spectrum)
        player.frameFiltering.add(entry: "melox.spectrum") { buffer, _ in
            analyzer.process(buffer: buffer)
        }
        #endif
        player.play(url: source.url, headers: source.headers)
    }

    func play() {
        wantsPlayback = true
        // stopped 时重启码流；保留暂停期间记录的 seek 目标位置。
        if player?.state == .stopped { seek(to: initialSeek ?? 0) }
        player?.resume()
        if isReady { transition(to: .playing) }
    }

    func resumeInPlace() {
        wantsPlayback = true
        player?.resume()
        if isReady { transition(to: .playing) }
    }

    func play(atRate rate: Float) { self.rate = rate }

    func pause() {
        wantsPlayback = false
        // A muted seek keeps decoding until it can settle at the requested sample.
        if !isSeeking {
            player?.pause()
            if hasCurrentItem { transition(to: .paused) }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { initialSeek = max(seconds, 0); return }
        finishedPosition = nil
        if player.state == .stopped, let source {
            // eof 之后的 stopped：只记录目标位置，不重启码流。重启会让
            // vendor 立刻开播，再靠 wantsPlayback=false 兜底暂停，产生
            // 一次无意义的拉流和一声杂音。真正播放时 play() 会重启。
            currentEntryID = nil
            initialSeek = max(seconds, 0)
            if wantsPlayback {
                isSeeking = true
                player.volume = 0
                transition(to: .loading)
                player.play(url: source.url, headers: source.headers)
            } else {
                isSeeking = false
                transition(to: .paused)
            }
            return
        }
        isSeeking = true
        player.volume = 0
        transition(to: .loading)
        player.seek(to: max(seconds, 0))
        player.resume()
    }

    func setEqualizerConfiguration(_ configuration: AudioEqualizerConfiguration) {
        equalizer.update(configuration: configuration)
    }
    func setAutoMixEqualizer(lowGain: Float, midGain: Float, highGain: Float) {
        equalizer.setAutoMixGains(low: lowGain, mid: midGain, high: highGain)
    }
    func resetAutoMixEqualizer() { setAutoMixEqualizer(lowGain: 0, midGain: 0, highGain: 0) }
    func setSpatializationEnabled(_ isEnabled: Bool) {
        player?.renderingAlgorithm = isEnabled ? .auto : .equalPowerPanning
    }

    func clear() {
        itemID = nil
        itemIdentifier = nil
        source = nil
        finishedPosition = nil
        currentEntryID = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        initialSeek = nil
        isSeeking = false
        wantsPlayback = false
        playbackRate = 1
        error = nil
        resetAutoMixEqualizer()
        formatTask?.cancel()
        formatTask = nil
        completeLoad(false)
        transition(to: .idle)
    }

    private func completeLoad(_ ready: Bool) {
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(returning: ready)
    }

    private func transition(to newState: AudioPlaybackState) {
        guard state != newState else { return }
        state = newState
        onStateChanged?()
    }

    func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        guard player === self.player else { return }
        currentEntryID = entryId
        guard let target = initialSeek else { return }
        initialSeek = nil
        player.seek(to: target)
    }

    func audioPlayerStateChanged(player: AudioStreaming.AudioPlayer,
                                 with newState: AudioPlayerState, previous: AudioPlayerState) {
        // The vendor posts delegate events to the main queue. A buffering or
        // paused event from preroll can arrive after this same player resumed.
        guard player === self.player, player.state == newState else { return }
        if newState != previous {
            // 欠载证据：播放中出现 bufferring 说明环形缓冲耗尽。
            rigTrace("deck", "state \(previous) -> \(newState)")
        }
        switch newState {
        case .playing:
            rigTrace("deck", "playing event wants=\(wantsPlayback) seeking=\(isSeeking) initial=\(String(describing: initialSeek)) vendorSeeking=\(player.isSeeking)")
            guard initialSeek == nil, !player.isSeeking, finishedPosition == nil, error == nil else { return }
            let completedSeek = isSeeking
            isSeeking = false
            if !wantsPlayback { player.pause() }
            player.volume = outputVolume
            completeLoad(true)
            transition(to: wantsPlayback ? .playing : .paused)
            if completedSeek, player === self.player, !isSeeking { onSeekCompleted?() }
        case .bufferring, .running:
            transition(to: .loading)
        case .paused:
            if !isSeeking { transition(to: .paused) }
        case .ready, .stopped, .error, .disposed:
            break
        }
    }

    func audioPlayerDidFinishPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId,
                                     stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        guard player === self.player, currentEntryID == entryId, stopReason == .eof,
              finishedPosition == nil, error == nil else { return }
        finishedPosition = progress
        isSeeking = false
        wantsPlayback = false
        completeLoad(false)
        transition(to: .paused)
        if player === self.player, finishedPosition != nil { onEnded?() }
    }
    func audioPlayerUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        guard player === self.player, self.error == nil, finishedPosition == nil else { return }
        self.error = error
        isSeeking = false
        wantsPlayback = false
        completeLoad(false)
        transition(to: .paused)
        if player === self.player { onFailure?(error) }
    }
    func audioPlayerDidFinishBuffering(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {}
    func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String: String]) {}
}
