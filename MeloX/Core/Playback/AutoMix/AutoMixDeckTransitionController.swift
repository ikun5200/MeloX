@preconcurrency import AVFoundation
import Foundation

enum AutoMixPreparationError: LocalizedError {
    case itemFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .itemFailed(let error):
            error?.localizedDescription
                ?? L10n.string("ui.error.automix.preload_failed")
        }
    }
}

@MainActor
final class AutoMixDeckTransitionController {
    var onTransitionBegan:
        ((Int, AutoMixTransitionPlan) -> Void)?
    var onTransitionProgress: ((Double) -> Void)?
    var onTransitionCompleted: ((Int) -> Void)?
    var onPreparationFailed:
        ((Int, Error) -> Void)?
    var onActiveDeckChanged: (() -> Void)?

    let decks: [AudioPlaybackDeck]
    private(set) var activeDeckIndex = 0

    private enum Purpose {
        case standby(token: UUID)
        case autoMix(identifier: Int, plan: AutoMixTransitionPlan)
    }

    // A single owner from the start of the load until promotion, cancellation
    // or the start of a fade. The item ID changes even when a token is reused.
    private struct Preparation {
        let purpose: Purpose
        let deckIndex: Int
        let itemID = UUID()
        var ready = false
    }

    private final class ActiveTransition {
        let identifier: Int
        let outgoingDeckIndex: Int
        let incomingDeckIndex: Int
        let plan: AutoMixTransitionPlan
        let outgoingStartPosition:
            TimeInterval
        let incomingStartPosition:
            TimeInterval
        var lastProgress = 0.0
        var lastPublishedProgress = 0.0

        init(
            identifier: Int,
            outgoingDeckIndex: Int,
            incomingDeckIndex: Int,
            plan: AutoMixTransitionPlan,
            outgoingStartPosition:
                TimeInterval,
            incomingStartPosition:
                TimeInterval
        ) {
            self.identifier = identifier
            self.outgoingDeckIndex =
                outgoingDeckIndex
            self.incomingDeckIndex =
                incomingDeckIndex
            self.plan = plan
            self.outgoingStartPosition =
                outgoingStartPosition
            self.incomingStartPosition =
                incomingStartPosition
        }
    }

    private var baseVolume: Float = 1
    private var deckGains: [Float] = [1, 0]
    private var preparation: Preparation?
    private var activeTransition:
        ActiveTransition?
    private var envelopeTask:
        Task<Void, Never>?
    private var wantsPlayback = false

    var activeDeck: AudioPlaybackDeck {
        decks[activeDeckIndex]
    }

    var hasPreparedTransition: Bool {
        if activeTransition != nil { return true }
        guard let preparation, case .autoMix = preparation.purpose else { return false }
        return preparation.ready
    }

    private var standbyDeckIndex: Int {
        activeDeckIndex == 0 ? 1 : 0
    }

    init(equalizerConfiguration: AudioEqualizerConfiguration) {
        decks = [
            AudioPlaybackDeck(equalizerConfiguration: equalizerConfiguration),
            AudioPlaybackDeck(equalizerConfiguration: equalizerConfiguration),
        ]
        applyOutputVolumes()
    }

    deinit {
        envelopeTask?.cancel()
    }

    func prepare(
        _ source: PlaybackSource,
        identifier: Int,
        plan: AutoMixTransitionPlan
    ) async -> Bool {
        guard plan.duration > 0, activeTransition == nil, !Task.isCancelled else { return false }
        // AutoMix has priority over ordinary standby, including an in-flight load.
        return await prepareInactiveDeck(source, purpose: .autoMix(identifier: identifier, plan: plan))
    }

    func prepareStandby(_ source: PlaybackSource, token: UUID) async -> Bool {
        guard activeTransition == nil, !Task.isCancelled else { return false }
        if let preparation {
            guard case .standby(let existing) = preparation.purpose else { return false }
            if existing == token { return canPromoteStandby(token: token) }
        }
        return await prepareInactiveDeck(source, purpose: .standby(token: token))
    }

    private func prepareInactiveDeck(_ source: PlaybackSource, purpose: Purpose) async -> Bool {
        clearPreparation()
        let request = Preparation(purpose: purpose, deckIndex: standbyDeckIndex)
        preparation = request
        let deck = decks[request.deckIndex]
        deckGains[request.deckIndex] = 0
        deck.volume = 0
        let ready: Bool
        switch purpose {
        case .standby:
            ready = await deck.load(source, itemID: request.itemID, startAt: 0, autoplay: false, timeout: .seconds(30))
        case let .autoMix(identifier, plan):
            ready = await deck.load(source, itemID: request.itemID, identifier: identifier, startAt: plan.incomingStartTime)
        }
        guard preparation?.itemID == request.itemID else { return false }
        guard !Task.isCancelled else { clearPreparation(); return false }
        guard ready, deck.itemID == request.itemID, deck.isPrerolled else {
            failPreparation(request, error: deck.error)
            return false
        }
        if case .standby = purpose {
            // The first playing delegate follows a render quantum. If main was
            // stalled long enough to lose the intro, prefer a cold load from zero.
            guard let position = deck.currentPlaybackTime, position <= 0.1 else {
                clearPreparation()
                return false
            }
        }
        preparation?.ready = true
        return true
    }

    func canPromoteStandby(token: UUID) -> Bool {
        guard let preparation, preparation.ready, case .standby(token) = preparation.purpose,
              preparation.deckIndex == standbyDeckIndex else { return false }
        let deck = decks[preparation.deckIndex]
        return deck.itemID == preparation.itemID && deck.isPrerolled
    }

    /// Both decks stay at [full, silent] until this explicit consumption. No
    /// clock, outgoing position, fade envelope or AutoMix callback drives it.
    func promoteStandby(token: UUID, autoplay: Bool) -> Bool {
        guard canPromoteStandby(token: token) else { return false }
        let outgoing = activeDeck
        preparation = nil
        activeDeckIndex = standbyDeckIndex
        wantsPlayback = autoplay
        outgoing.clear() // Already inactive: its synchronous .idle cannot escape.
        deckGains = activeDeckIndex == 0 ? [1, 0] : [0, 1]
        applyOutputVolumes()
        if autoplay { activeDeck.resumeInPlace() }
        return true
    }

    func cancelStandby() {
        guard let preparation, case .standby = preparation.purpose else { return }
        clearPreparation()
    }

    func cancel(wantsPlayback: Bool) {
        self.wantsPlayback = wantsPlayback
        if let preparation, case .autoMix = preparation.purpose { clearPreparation() }
        // No running fade means there is nothing to restore on the active deck.
        // In particular, setting rate=1 here used to restart an item at EOF.
        guard let transition = activeTransition else { return }
        activeTransition = nil
        envelopeTask?.cancel()
        envelopeTask = nil
        decks[transition.incomingDeckIndex].clear()
        resetAutoMixEqualizers()
        deckGains = activeDeckIndex == 0 ? [1, 0] : [0, 1]
        activeDeck.rate = wantsPlayback ? 1 : 0
        applyOutputVolumes()
        onTransitionProgress?(0)
    }

    func reset() {
        cancelStandby()
        cancel(wantsPlayback: false)
        for deck in decks {
            deck.clear()
        }
        activeDeckIndex = 0
        deckGains = [1, 0]
        applyOutputVolumes()
    }

    func setVolume(_ volume: Double) {
        baseVolume = Float(
            min(max(volume, 0), 1)
        )
        applyOutputVolumes()
    }

    func pauseAll() {
        wantsPlayback = false
        for deck in decks {
            deck.pause()
        }
    }

    func resumeIncomingIfNeeded() {
        wantsPlayback = true
        guard let activeTransition else {
            return
        }
        let progress = currentProgress(
            for: activeTransition
        )
        decks[
            activeTransition.outgoingDeckIndex
        ].rate = outgoingRate(
            for: activeTransition,
            progress: progress
        )
        decks[
            activeTransition.incomingDeckIndex
        ].play(
            atRate:
                incomingRate(
                    for: activeTransition,
                    progress: progress
                )
        )
    }

    func startIfNeeded(wantsPlayback: Bool) {
        self.wantsPlayback = wantsPlayback
        guard activeTransition == nil, wantsPlayback, let preparation, preparation.ready,
              case let .autoMix(identifier, plan) = preparation.purpose,
              preparation.deckIndex == standbyDeckIndex,
              decks[preparation.deckIndex].isPrerolled,
              decks[preparation.deckIndex].itemID == preparation.itemID,
              let seconds = activeDeck.currentPlaybackTime, seconds >= plan.outgoingStartTime else { return }
        start(identifier: identifier, deckIndex: preparation.deckIndex, plan: plan)
    }

    func finishIfOutgoingEnded(at deckIndex: Int, wantsPlayback: Bool) -> Bool {
        self.wantsPlayback = wantsPlayback
        guard let activeTransition, activeTransition.outgoingDeckIndex == deckIndex else { return false }
        finish(activeTransition, wantsPlayback: wantsPlayback)
        return true
    }

    private func start(identifier: Int, deckIndex: Int, plan: AutoMixTransitionPlan) {
        let transition = ActiveTransition(
            identifier: identifier,
            outgoingDeckIndex: activeDeckIndex,
            incomingDeckIndex: deckIndex,
            plan: plan,
            outgoingStartPosition: activeDeck.currentPlaybackTime ?? plan.outgoingStartTime,
            incomingStartPosition: decks[deckIndex].currentPlaybackTime ?? plan.incomingStartTime
        )
        preparation = nil
        activeTransition = transition
        deckGains[
            transition.outgoingDeckIndex
        ] = 1
        deckGains[
            transition.incomingDeckIndex
        ] = 0
        applyAutoMixEqualizer(
            progress: 0,
            transition: transition
        )
        applyOutputVolumes()
        decks[transition.incomingDeckIndex].play(
                atRate:
                    incomingRate(
                        for: transition,
                        progress: 0
                    )
            )
        onTransitionBegan?(
            transition.identifier,
            transition.plan
        )
        if activeTransition === transition { runEnvelope(transition) }
    }

    private func runEnvelope(
        _ transition: ActiveTransition
    ) {
        envelopeTask?.cancel()
        envelopeTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let current =
                    self.activeTransition,
                  current === transition {
                let progress =
                    self.currentProgress(
                        for: current
                    )
                let gains =
                    AutoMixFadeEnvelope.gains(
                        at: progress,
                        curve:
                            current.plan.fadeCurve
                    )
                self.deckGains[
                    current.outgoingDeckIndex
                ] = gains.outgoing
                self.deckGains[
                    current.incomingDeckIndex
                ] = gains.incoming
                self.applyAutoMixEqualizer(
                    progress: progress,
                    transition: current
                )
                self.applyOutputVolumes()

                let outgoingPlayer =
                    self.decks[
                        current.outgoingDeckIndex
                    ]
                let incomingPlayer =
                    self.decks[
                        current.incomingDeckIndex
                    ]
                if self.wantsPlayback {
                    outgoingPlayer.rate =
                        self.outgoingRate(
                            for: current,
                            progress: progress
                        )
                    incomingPlayer.rate =
                        self.incomingRate(
                            for: current,
                            progress: progress
                        )
                } else {
                    if outgoingPlayer.rate != 0 {
                        outgoingPlayer.pause()
                    }
                    if incomingPlayer.rate != 0 {
                        incomingPlayer.pause()
                    }
                }
                self.publishProgressIfNeeded(
                    progress,
                    transition: current
                )
                if progress >= 1 {
                    self.finish(
                        current,
                        wantsPlayback:
                            self.wantsPlayback
                    )
                    return
                }
                try? await Task.sleep(
                    for: .milliseconds(20)
                )
            }
        }
    }

    private func currentProgress(
        for transition: ActiveTransition
    ) -> Double {
        guard let outgoingPosition = decks[
                  transition.outgoingDeckIndex
              ].currentPlaybackTime,
              let incomingPosition = decks[
                  transition.incomingDeckIndex
              ].currentPlaybackTime else {
            return transition.lastProgress
        }

        let outgoingProgress =
            AutoMixTempoEnvelope.progress(
                forContentDuration:
                    max(
                        outgoingPosition
                            - transition
                                .outgoingStartPosition,
                        0
                    ),
                wallClockDuration:
                    transition.plan.duration,
                startRate: 1,
                endRate:
                    transition.plan
                        .outgoingEndPlaybackRate
            )
        let incomingProgress =
            AutoMixTempoEnvelope.progress(
                forContentDuration:
                    max(
                        incomingPosition
                            - transition
                                .incomingStartPosition,
                        0
                    ),
                wallClockDuration:
                    transition.plan.duration,
                startRate:
                    transition.plan
                        .incomingStartPlaybackRate,
                endRate: 1
            )
        transition.lastProgress = max(
            transition.lastProgress,
            min(
                max(
                    min(
                        outgoingProgress,
                        incomingProgress
                    ),
                    0
                ),
                1
            )
        )
        return transition.lastProgress
    }

    private func outgoingRate(
        for transition: ActiveTransition,
        progress: Double
    ) -> Float {
        AutoMixTempoEnvelope.playbackRate(
            at: progress,
            startRate: 1,
            endRate:
                transition.plan
                    .outgoingEndPlaybackRate
        )
    }

    private func incomingRate(
        for transition: ActiveTransition,
        progress: Double
    ) -> Float {
        AutoMixTempoEnvelope.playbackRate(
            at: progress,
            startRate:
                transition.plan
                    .incomingStartPlaybackRate,
            endRate: 1
        )
    }

    private func finish(
        _ transition: ActiveTransition,
        wantsPlayback: Bool
    ) {
        guard activeTransition === transition else { return }
        envelopeTask?.cancel()
        envelopeTask = nil
        activeTransition = nil // A synchronous deck callback can now safely cancel AutoMix.
        activeDeckIndex = transition.incomingDeckIndex
        decks[transition.outgoingDeckIndex].clear()
        resetAutoMixEqualizers()
        activeDeck.rate =
            wantsPlayback ? 1 : 0
        deckGains = activeDeckIndex == 0
            ? [1, 0]
            : [0, 1]
        applyOutputVolumes()
        onActiveDeckChanged?()
        onTransitionProgress?(1)
        onTransitionCompleted?(
            transition.identifier
        )
    }

    func inactiveDeckFailed(at index: Int, itemID: UUID?, error: Error?) {
        guard let preparation, index == standbyDeckIndex, preparation.deckIndex == index,
              preparation.itemID == itemID else { return }
        failPreparation(preparation, error: error)
    }

    private func failPreparation(_ request: Preparation, error: Error?) {
        clearPreparation()
        if case let .autoMix(identifier, _) = request.purpose {
            onPreparationFailed?(identifier, AutoMixPreparationError.itemFailed(error))
        }
    }

    private func clearPreparation() {
        guard let request = preparation else { return }
        preparation = nil
        let index = request.deckIndex
        guard index == standbyDeckIndex, decks[index].itemID == request.itemID else { return }
        decks[index].clear()
        deckGains[index] = 0
    }

    private func applyOutputVolumes() {
        for index in decks.indices {
            decks[index].volume =
                baseVolume * deckGains[index]
        }
    }

    private func applyAutoMixEqualizer(
        progress: Double,
        transition: ActiveTransition
    ) {
        let adjustments =
            AutoMixEqualizerEnvelope
                .adjustments(at: progress)
        decks[
            transition.outgoingDeckIndex
        ].setAutoMixEqualizer(
            lowGain:
                adjustments.outgoing.low,
            midGain:
                adjustments.outgoing.mid,
            highGain:
                adjustments.outgoing.high
        )
        decks[
            transition.incomingDeckIndex
        ].setAutoMixEqualizer(
            lowGain:
                adjustments.incoming.low,
            midGain:
                adjustments.incoming.mid,
            highGain:
                adjustments.incoming.high
        )
    }

    private func resetAutoMixEqualizers() {
        for deck in decks {
            deck.resetAutoMixEqualizer()
        }
    }

    private func publishProgressIfNeeded(
        _ progress: Double,
        transition: ActiveTransition
    ) {
        let minimumStep = max(
            0.004,
            0.08
                / max(
                    transition.plan.duration,
                    0.1
                )
        )
        guard progress >= 1
                || progress
                    - transition
                        .lastPublishedProgress
                    >= minimumStep else {
            return
        }
        transition.lastPublishedProgress =
            progress
        onTransitionProgress?(progress)
    }

    private func normalizedRate(
        _ rate: Double
    ) -> Float {
        Float(min(max(rate, 0.5), 2))
    }

}
