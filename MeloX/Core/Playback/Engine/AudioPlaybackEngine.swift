@preconcurrency import AVFoundation
import Foundation

enum AudioPlaybackState: Equatable {
    case idle
    case loading
    case paused
    case playing
}

struct AudioSessionInterruptionBegan: Sendable {
    var routeDisconnected: Bool
    var wasSuspended: Bool
    var reason: AVAudioSession.InterruptionReason?
}

enum AudioPlaybackError: LocalizedError {
    case audioSession(Error)
    case itemFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .audioSession(let error):
            L10n.format("ui.error.playback.enable_failed", error.localizedDescription)
        case .itemFailed(let error):
            if let error {
                L10n.format("ui.error.playback.audio_source_failed", error.localizedDescription)
            } else {
                L10n.string("ui.error.playback.audio_source_retry")
            }
        }
    }
}

@MainActor
final class AudioPlaybackEngine {
    var onStateChanged: ((AudioPlaybackState) -> Void)?
    var onPlaybackClockChanged: ((AudioPlaybackClockSample) -> Void)?
    var onDurationChanged: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onAutoMixTransitionBegan: ((Int, AutoMixTransitionPlan) -> Void)?
    var onAutoMixTransitionProgress: ((Double) -> Void)?
    var onAutoMixTransitionCompleted: ((Int) -> Void)?
    var onAutoMixPreparationFailed: ((Int, Error) -> Void)?
    var onInterruptionBegan: ((AudioSessionInterruptionBegan) -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onOutputDeviceDisconnected: (() -> Void)?

    private(set) var state: AudioPlaybackState = .idle
    private let autoMixController: AutoMixDeckTransitionController
    private var clockTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var wantsPlayback = false
    private var pendingSeekTime: TimeInterval?
    private var didReportCurrentItemFailure = false
    private var loadGeneration = 0
    private var isPromotingStandby = false
    #if os(macOS)
    private var spatialAudioMode: SpatialAudioMode
    #endif

    private var decks: [AudioPlaybackDeck] { autoMixController.decks }
    private var activeDeckIndex: Int { autoMixController.activeDeckIndex }
    private var activeDeck: AudioPlaybackDeck { autoMixController.activeDeck }
    var hasCurrentItem: Bool { activeDeck.hasCurrentItem }
    var currentPlaybackTime: TimeInterval? { activeDeck.currentPlaybackTime }
    var expectsPlaybackToContinue: Bool { wantsPlayback }
    var hasPreparedAutoMix: Bool { autoMixController.hasPreparedTransition }
    #if os(iOS)
    var audioSpectrumSnapshot: PlaybackAudioSpectrumSnapshot { activeDeck.spectrumSnapshot }
    #endif

    init(equalizerConfiguration: AudioEqualizerConfiguration) {

        autoMixController = AutoMixDeckTransitionController(
            equalizerConfiguration: equalizerConfiguration
        )
        bindDecks()
        bindAutoMixController()
        #if os(iOS)
        installAudioSessionObservers()
        #endif
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self else { return }
                guard self.state == .playing else { continue }
                self.publishPlaybackClockSample(origin: .periodic)
                self.publishDurationIfAvailable()
                self.autoMixController.startIfNeeded(wantsPlayback: self.wantsPlayback)
            }
        }
    }

    deinit {
        clockTask?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func load(_ source: PlaybackSource, startAt: TimeInterval = 0, autoplay: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        cancelStandby()
        autoMixController.cancel(wantsPlayback: false)
        wantsPlayback = autoplay
        didReportCurrentItemFailure = false
        let target = pendingSeekTime ?? max(startAt, 0)
        pendingSeekTime = nil
        transition(to: .loading)
        do { try AudioPlaybackSessionConfigurator.activate() }
        catch { fail(with: AudioPlaybackError.audioSession(error)); return }
        _ = await activeDeck.load(source, startAt: target, autoplay: autoplay)
        guard generation == loadGeneration else { return }
        publishDurationIfAvailable()
        updateStateFromPlayer(clockOrigin: .activeItemChanged)
    }

    func unload() {
        loadGeneration += 1
        wantsPlayback = false
        pendingSeekTime = nil
        didReportCurrentItemFailure = false
        autoMixController.reset()
        transition(to: .idle)
    }

    func play() {
        wantsPlayback = true
        guard hasCurrentItem else { return }
        do {
            try AudioPlaybackSessionConfigurator.activate()
            activeDeck.play()
            autoMixController.resumeIncomingIfNeeded()
            updateStateFromPlayer()
        } catch { fail(with: AudioPlaybackError.audioSession(error)) }
    }

    /// Continue the current item after a session-category change.
    /// Does not seek and does not reload the source.
    func resumeInPlace() {
        wantsPlayback = true
        guard hasCurrentItem else { return }
        do {
            try AudioPlaybackSessionConfigurator.activate()
        } catch {
            return
        }
        activeDeck.resumeInPlace()
        autoMixController.resumeIncomingIfNeeded()
        updateStateFromPlayer()
    }

    func pause() {
        wantsPlayback = false
        autoMixController.pauseAll()
        updateStateFromPlayer()
    }

    func seek(to seconds: TimeInterval) {
        guard hasCurrentItem else { pendingSeekTime = max(seconds, 0); return }
        cancelAutoMix()
        activeDeck.seek(to: seconds)
        updateStateFromPlayer()
    }

    func setVolume(_ volume: Double) { autoMixController.setVolume(volume) }
    func setEqualizerConfiguration(_ configuration: AudioEqualizerConfiguration) {
        for deck in decks { deck.setEqualizerConfiguration(configuration) }
    }
    #if os(macOS)
    func setSpatialAudioMode(_ mode: SpatialAudioMode) {
        spatialAudioMode = mode
        for deck in decks { AudioSpatializationPolicy.apply(mode, to: deck) }
    }
    #endif

    func prepareStandby(_ source: PlaybackSource, token: UUID) async -> Bool {
        await autoMixController.prepareStandby(source, token: token)
    }

    /// On false the active item is unchanged. On true the new deck is already
    /// active and `state` is readable, but no song/state/clock callback is made
    /// in this call. The store must set its song and clock before yielding MainActor.
    func promoteStandby(token: UUID, autoplay: Bool) -> Bool {
        guard autoMixController.canPromoteStandby(token: token) else { return false }
        isPromotingStandby = true
        defer { isPromotingStandby = false }
        if autoplay {
            do { try AudioPlaybackSessionConfigurator.activate() }
            catch { cancelStandby(); return false }
        }
        guard autoMixController.promoteStandby(token: token, autoplay: autoplay) else { return false }
        loadGeneration += 1
        wantsPlayback = autoplay
        pendingSeekTime = nil
        didReportCurrentItemFailure = false
        state = activeDeck.state
        let generation = loadGeneration
        let itemID = activeDeck.itemID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isCurrent = { self.loadGeneration == generation && self.activeDeck.itemID == itemID }
            guard isCurrent() else { return }
            self.publishDurationIfAvailable()
            guard isCurrent() else { return }
            // Even playing -> playing (or paused -> paused) is a new store item.
            self.onStateChanged?(self.state)
            guard isCurrent() else { return }
            self.publishPlaybackClockSample(origin: .activeItemChanged)
        }
        return true
    }

    func cancelStandby() { autoMixController.cancelStandby() }

    func prepareAutoMix(_ source: PlaybackSource, identifier: Int, plan: AutoMixTransitionPlan) async {
        if await autoMixController.prepare(source, identifier: identifier, plan: plan) {
            autoMixController.startIfNeeded(wantsPlayback: wantsPlayback)
        }
    }
    func cancelAutoMix() { autoMixController.cancel(wantsPlayback: wantsPlayback) }

    private func bindDecks() {
        for (index, deck) in decks.enumerated() {
            deck.onStateChanged = { [weak self, weak deck] in
                guard let self, let deck else { return }
                #if os(macOS)
                if deck.isReady { AudioSpatializationPolicy.apply(self.spatialAudioMode, to: deck) }
                #endif
                if index == self.activeDeckIndex, !self.isPromotingStandby { self.updateStateFromPlayer() }
            }
            deck.onSeekCompleted = { [weak self] in
                guard let self, index == self.activeDeckIndex, !self.isPromotingStandby else { return }
                self.publishPlaybackClockSample(origin: .seekCompleted)
            }
            deck.onEnded = { [weak self, weak deck] in
                guard let self, let deck else { return }
                if index != self.activeDeckIndex {
                    self.autoMixController.inactiveDeckFailed(at: index, itemID: deck.itemID, error: nil)
                } else if !self.autoMixController.finishIfOutgoingEnded(at: index, wantsPlayback: self.wantsPlayback) {
                    self.onPlaybackEnded?()
                }
            }
            deck.onFailure = { [weak self, weak deck] error in
                guard let self, let deck else { return }
                if index == self.activeDeckIndex { self.fail(with: AudioPlaybackError.itemFailed(error)) }
                else { self.autoMixController.inactiveDeckFailed(at: index, itemID: deck.itemID, error: error) }
            }
        }
    }

    private func bindAutoMixController() {
        autoMixController.onTransitionBegan = { [weak self] identifier, plan in
            self?.onAutoMixTransitionBegan?(identifier, plan)
        }
        autoMixController.onTransitionProgress = { [weak self] in self?.onAutoMixTransitionProgress?($0) }
        autoMixController.onTransitionCompleted = { [weak self] identifier in
            guard let self else { return }
            self.onAutoMixTransitionCompleted?(identifier)
            self.publishDurationIfAvailable()
            self.updateStateFromPlayer(clockOrigin: .activeItemChanged)
        }
        autoMixController.onPreparationFailed = { [weak self] identifier, error in
            self?.onAutoMixPreparationFailed?(identifier, error)
        }
    }

    private func updateStateFromPlayer(clockOrigin: AudioPlaybackClockSample.Origin = .stateChanged) {
        transition(to: activeDeck.state)
        publishPlaybackClockSample(origin: clockOrigin)
    }
    private func publishDurationIfAvailable() {
        if let duration = activeDeck.playbackDuration { onDurationChanged?(duration) }
    }
    private func publishPlaybackClockSample(origin: AudioPlaybackClockSample.Origin) {
        guard let seconds = currentPlaybackTime else { return }
        onPlaybackClockChanged?(AudioPlaybackClockSample(
            position: seconds, rate: Double(activeDeck.rate), sampledAt: Date(), origin: origin
        ))
    }
    private func fail(with error: Error) {
        guard !didReportCurrentItemFailure else { return }
        didReportCurrentItemFailure = true
        wantsPlayback = false
        autoMixController.pauseAll()
        publishPlaybackClockSample(origin: .stateChanged)
        onFailure?(error)
    }
    private func transition(to newState: AudioPlaybackState) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleInterruption(notification)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName:
                    AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleRouteChange(notification)
                }
            }
        )
    }

    private func handleInterruption(
        _ notification: Notification
    ) {
        guard let rawType = notification.userInfo?[
            AVAudioSessionInterruptionTypeKey
        ] as? UInt,
              let type =
                AVAudioSession.InterruptionType(
                    rawValue: rawType
                ) else {
            return
        }
        switch type {
        case .began:
            let rawReason = notification.userInfo?[
                AVAudioSessionInterruptionReasonKey
            ] as? UInt
            let reason = rawReason.flatMap {
                AVAudioSession.InterruptionReason(rawValue: $0)
            }
            let wasSuspended = notification.userInfo?[
                AVAudioSessionInterruptionWasSuspendedKey
            ] as? Bool ?? false
            onInterruptionBegan?(
                AudioSessionInterruptionBegan(
                    routeDisconnected: reason == .routeDisconnected,
                    wasSuspended: wasSuspended,
                    reason: reason
                )
            )
        case .ended:
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0
            let shouldResume =
                AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions
                ).contains(.shouldResume)
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(
        _ notification: Notification
    ) {
        guard let rawReason = notification.userInfo?[
            AVAudioSessionRouteChangeReasonKey
        ] as? UInt,
              AVAudioSession.RouteChangeReason(
                rawValue: rawReason
              ) == .oldDeviceUnavailable else {
            return
        }
        pause()
        onOutputDeviceDisconnected?()
    }
}
