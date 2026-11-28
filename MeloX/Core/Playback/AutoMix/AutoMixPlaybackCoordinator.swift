import Foundation

nonisolated struct PreparedAutoMixContext {
    let token: UUID
    let outgoingSongID: Int
    let incomingSong: Song
    let source: PlaybackSource
    let sourceIsDownloaded: Bool
}

@MainActor
final class AutoMixPlaybackCoordinator {
    var onTransitionBegan:
        ((PreparedAutoMixContext, AutoMixTransitionPlan) -> Void)?
    var onTransitionProgress: ((Double) -> Void)?
    var onTransitionCompleted: ((PreparedAutoMixContext) -> Void)?
    var isCurrentPreparation: ((UUID) -> Bool)?

    private struct PlannedTransition {
        let context: PreparedAutoMixContext
        let plan: AutoMixTransitionPlan
        let outgoingDuration: TimeInterval
    }

    private let downloads: DownloadStore
    private let engine: AudioPlaybackEngine
    private let analyzer: AutoMixAudioAnalyzer
    private var planningTask: Task<Void, Never>?
    private var deckPreparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var attempt: UUID?
    private var plannedTransition: PlannedTransition?
    private var preparedContext: PreparedAutoMixContext?
    private var transitionHasBegun = false
    private var latestRemainingTime = TimeInterval.infinity
    private var latestPreloadLeadTime: TimeInterval = 0

    init(downloads: DownloadStore, engine: AudioPlaybackEngine, analyzer: AutoMixAudioAnalyzer) {
        self.downloads = downloads
        self.engine = engine
        self.analyzer = analyzer
        bindEngine()
    }

    func prepareIfNeeded(
        token: UUID,
        outgoingSong: Song,
        outgoingSource: PlaybackSource,
        outgoingSourceIsDownloaded: Bool,
        outgoingDuration: TimeInterval,
        outgoingProgress: TimeInterval,
        incomingSong: Song,
        incomingSource: SelectedPlaybackSource,
        configuration: AutoMixConfiguration
    ) {
        guard !transitionHasBegun else { return }
        if let attempt, attempt != token { cancel() }
        let outgoingDuration = max(outgoingDuration, Self.duration(of: outgoingSong))
        latestRemainingTime = max(outgoingDuration - outgoingProgress, 0)
        latestPreloadLeadTime = configuration.preloadLeadTime
        if plannedTransition != nil {
            prepareDeckIfNeeded()
            return
        }
        guard attempt != token else { return }
        attempt = token
        preparationGeneration += 1
        let generation = preparationGeneration
        // 配对分析要解码并推理两首完整歌曲，保持在 utility 优先级，
        // 不与正在播放的解码链抢 CPU。
        planningTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if generation == preparationGeneration { planningTask = nil }
            }
            let analysis = await self.analysis(
                configuration: configuration,
                outgoingSong: outgoingSong,
                outgoingSource: outgoingSource,
                outgoingSourceIsDownloaded: outgoingSourceIsDownloaded,
                outgoingDuration: outgoingDuration,
                incomingSong: incomingSong,
                incomingSource: incomingSource
            )
            guard !Task.isCancelled, generation == preparationGeneration,
                  isCurrentPreparation?(token) == true,
                  let plan = AutoMixTransitionPlanner.makePlan(
                      configuration: configuration,
                      outgoingDuration: outgoingDuration,
                      incomingDuration: Self.duration(of: incomingSong),
                      analysis: analysis
                  ) else { return }
            let context = PreparedAutoMixContext(
                token: token, outgoingSongID: outgoingSong.id, incomingSong: incomingSong,
                source: incomingSource.source, sourceIsDownloaded: incomingSource.isDownloaded
            )
            plannedTransition = PlannedTransition(context: context, plan: plan, outgoingDuration: outgoingDuration)
            prepareDeckIfNeeded()
        }
    }

    private func prepareDeckIfNeeded() {
        guard let plannedTransition, deckPreparationTask == nil,
              preparedContext == nil, !engine.hasPreparedAutoMix,
              !transitionHasBegun else { return }
        let transitionLeadTime = max(
            plannedTransition.outgoingDuration - plannedTransition.plan.outgoingStartTime + 12,
            latestPreloadLeadTime
        )
        guard latestRemainingTime <= transitionLeadTime else { return }
        self.plannedTransition = nil
        let context = plannedTransition.context
        preparedContext = context
        let generation = preparationGeneration
        deckPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == preparationGeneration { deckPreparationTask = nil }
            }
            guard !Task.isCancelled, isCurrentPreparation?(context.token) == true else { return }
            // Engine callbacks carry the attempt, not the possibly duplicate song ID.
            await engine.prepareAutoMix(context.source, identifier: generation, plan: plannedTransition.plan)
            guard !Task.isCancelled, generation == preparationGeneration,
                  preparedContext?.token == context.token else { return }
            if engine.hasPreparedAutoMix || transitionHasBegun {
                rigTrace("next", "ready token=\(context.token) to=\(context.incomingSong.id)")
            } else {
                preparedContext = nil
            }
        }
    }

    func cancel() {
        // cancelAutoMix touches both decks. A resolution/plan alone owns neither.
        let ownsDeck = preparedContext != nil || deckPreparationTask != nil || engine.hasPreparedAutoMix
        preparationGeneration += 1
        planningTask?.cancel()
        planningTask = nil
        deckPreparationTask?.cancel()
        deckPreparationTask = nil
        attempt = nil
        plannedTransition = nil
        preparedContext = nil
        transitionHasBegun = false
        latestRemainingTime = .infinity
        latestPreloadLeadTime = 0
        if ownsDeck { engine.cancelAutoMix() }
    }

    private func analysis(
        configuration: AutoMixConfiguration,
        outgoingSong: Song,
        outgoingSource: PlaybackSource,
        outgoingSourceIsDownloaded: Bool,
        outgoingDuration: TimeInterval,
        incomingSong: Song,
        incomingSource: SelectedPlaybackSource
    ) async -> AutoMixPairAnalysis? {
        guard configuration.mode == .smart,
              configuration.analyzesStreamingTracks || (outgoingSourceIsDownloaded && incomingSource.isDownloaded) else {
            return nil
        }
        return try? await analyzer.analyzePair(
            outgoing: AutoMixAnalysisRequest(
                songID: outgoingSong.id, source: outgoingSource,
                duration: outgoingDuration, isDownloaded: outgoingSourceIsDownloaded
            ),
            incoming: AutoMixAnalysisRequest(
                songID: incomingSong.id, source: incomingSource.source,
                duration: Self.duration(of: incomingSong), isDownloaded: incomingSource.isDownloaded
            )
        )
    }

    private func bindEngine() {
        engine.onAutoMixTransitionBegan = { [weak self] identifier, plan in
            guard let self, identifier == preparationGeneration,
                  let context = preparedContext else { return }
            guard isCurrentPreparation?(context.token) == true else { cancel(); return }
            transitionHasBegun = true
            onTransitionBegan?(context, plan)
        }
        engine.onAutoMixTransitionProgress = { [weak self] progress in
            guard let self, transitionHasBegun else { return }
            onTransitionProgress?(min(max(progress, 0), 1))
        }
        engine.onAutoMixTransitionCompleted = { [weak self] identifier in
            guard let self, identifier == preparationGeneration,
                  let context = preparedContext else { return }
            preparationGeneration += 1
            planningTask = nil
            deckPreparationTask = nil
            attempt = nil
            plannedTransition = nil
            preparedContext = nil
            transitionHasBegun = false
            onTransitionCompleted?(context)
        }
        engine.onAutoMixPreparationFailed = { [weak self] identifier, _ in
            guard let self, identifier == preparationGeneration,
                  let context = preparedContext else { return }
            preparedContext = nil
            transitionHasBegun = false
            if context.sourceIsDownloaded, isCurrentPreparation?(context.token) == true {
                downloads.discardInvalidDownload(songID: context.incomingSong.id)
            }
        }
    }

    #if DEBUG
    var debugDeckPreparation: String? {
        guard preparedContext != nil else { return nil }
        return engine.hasPreparedAutoMix ? "ready" : "buffering"
    }
    #endif

    private static func duration(of song: Song) -> TimeInterval {
        TimeInterval(song.durationMS) / 1_000
    }
}
