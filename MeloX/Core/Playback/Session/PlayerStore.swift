import Foundation
import Observation
import OSLog
import UIKit

private enum LyricsLiveActivityPublication: Equatable {
    case inactive
    case content(LyricsLiveActivityPublicationSignature)
}

private struct LyricsLiveActivityPublicationSignature: Equatable {
    let songID: Int
    let currentLyricID: LyricLine.ID?
    let nextLyricID: LyricLine.ID?
    let isPlaying: Bool
    let title: String
    let subtitle: String
    let compactText: String
    let compactScrollDistancePoints: Int
    let artworkURL: URL?
    let preferences: LyricsLiveActivityPreferences
    let durationMilliseconds: Int
}

private struct ListenTogetherSavedPlaybackOptions {
    let repeatMode: RepeatMode
    let wasShuffled: Bool
    let autoplayEnabled: Bool
    let autoMixEnabled: Bool
}

@MainActor
@Observable
final class PlayerStore {
    private static let beatAnalysisLogger = Logger(
        subsystem:
            Bundle.main.bundleIdentifier
                ?? "MeloX",
        category: "BeatNet"
    )

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var progress: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var seekRevision = 0
    private(set) var isLoading = false
    private(set) var playbackIssue: PlaybackIssue?
    private(set) var volume: Double = 1
    private(set) var isListenTogetherSessionActive = false
    private(set) var isHeartModeActive = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var isAutoplayEnabled = false
    private(set) var isAutoMixEnabled = false
    private(set) var autoMixTransitionProgress: Double?
    private(set) var autoMixTransitionKind:
        AutoMixTransitionKind?
    private(set) var autoMixIncomingSongName: String?
    private(set) var queueModeIndicator:
        QueuePlaybackModeIndicator?
    private(set) var currentBeatTimeline:
        PlaybackBeatTimeline?
    private(set) var beatAnalysisStatus:
        PlaybackBeatAnalysisStatus = .idle
    /// The tier of the stream that is playing. It is lower than
    /// `preferredPlaybackQuality` for a song that lacks the chosen tier.
    private(set) var effectivePlaybackQuality: MusicQuality?
    /// True while a newly chosen quality is being fetched. The current
    /// stream keeps playing until the new one is ready.
    private(set) var isSwitchingPlaybackQuality = false
    /// A short message shown in place of the quality label, for a choice
    /// this song cannot honour.
    private(set) var playbackQualityNotice: String?
    private(set) var sleepTimer: PlaybackSleepTimer

    var currentAudioSpectrum: PlaybackAudioSpectrumSnapshot {
        engine.audioSpectrumSnapshot
    }

    /// The quality the listener chose. It stands for every song: one that
    /// lacks it plays the next tier down, and the song after starts from
    /// this choice again.
    var preferredPlaybackQuality: MusicQuality {
        api.playbackQuality
    }

    /// The tiers the player's quality menu lists.
    var playbackQualityOptions: [MusicQuality] {
        guard currentSong != nil else { return [] }
        return selectablePlaybackQualities(
            including: preferredPlaybackQuality
        )
    }

    var selectedPlaybackQualityOption: MusicQuality { api.playbackQualityChoice }

    var isCurrentQualityVerified: Bool { currentPlaybackSource?.qualityVerified == true }

    /// This is evidence about the enabled sources, not the account's QQ catalog.
    func currentQualityEvidence(for tier: MusicQuality) -> LXQualityEvidence {
        guard let currentSong else { return .untested }
        return api.sourceEvidence(for: currentSong, quality: tier)
    }

    private var playbackQueue = PlaybackQueue() {
        didSet { queueRevision &+= 1 }
    }
    @ObservationIgnored private var queueRevision = 0
    @ObservationIgnored private var transportRevision = 0
    private var consecutiveSourceFailures = 0

    var queue: [Song] { playbackQueue.songs }
    var currentIndex: Int { playbackQueue.currentIndex }
    var isShuffled: Bool { playbackQueue.isShuffled }
    var unplayedQueueIndices: [Int] {
        playbackQueue.upcomingIndices(wraps: false)
    }
    var upcomingQueueIndices: [Int] {
        playbackQueue.upcomingIndices(
            wraps: repeatMode == .all
        )
    }
    var queueModeBadgeSystemImage: String? {
        queueModeIndicator?.systemImage
    }
    @ObservationIgnored
    var onListenTogetherTransport: ((ListenTogetherCommandType, Int?) -> Void)?

    @ObservationIgnored
    var onListenTogetherQueueEdit: (() -> Void)?

    var listenTogetherDisplaySongIDs: [Int] {
        queue.map(\.id)
    }
    /// Room playlist reports stay in display order. Shuffle only chooses the
    /// next track on this device; publishing the permutation makes the server
    /// echo a reordered queue back to both sides.
    var listenTogetherRandomSongIDs: [Int] {
        listenTogetherDisplaySongIDs
    }
    /// True while this device is resolving the next listen-together track and
    /// intends to play it. `isPlaying` is still false during that gap.
    var isPreparingListenTogetherAutoplay: Bool {
        isListenTogetherSessionActive
            && currentLoadShouldAutoplay
            && (isLoading || isResolvingSource)
    }
    var listenTogetherReportedPlaying: Bool {
        isPlaying || isPreparingListenTogetherAutoplay
    }
    var isAutoMixTransitioning: Bool {
        autoMixTransitionProgress != nil
    }
    var canPlayNext: Bool {
        isAutoplayEnabled
            || (
                queue.count > 1
                    && playbackQueue.canMove(
                        by: 1,
                        wraps: repeatMode == .all
                    )
            )
    }

    @ObservationIgnored
    private let api: NeteaseAPI

    private var currentSongAudioAvailability:
        SongAudioAvailability = .unknown

    private var isResolvingCurrentSongAudioAvailability = false

    @ObservationIgnored
    private var detailedPlaybackSongs: [Song.ID: Song] = [:]

    @ObservationIgnored
    private var audioAvailabilityTask: Task<Void, Never>?

    @ObservationIgnored
    private let settings: AppSettings

    @ObservationIgnored
    private let downloads: DownloadStore

    @ObservationIgnored
    private let engine: AudioPlaybackEngine

    @ObservationIgnored
    private let beatAnalyzer: AutoMixAudioAnalyzer

    @ObservationIgnored
    private let autoMixCoordinator:
        AutoMixPlaybackCoordinator

    @ObservationIgnored
    private let nowPlayingSession: NowPlayingSession

    @ObservationIgnored
    private let lyricsLiveActivityController:
        LyricsLiveActivityController

    @ObservationIgnored
    private let lyricsNotificationController:
        LyricsNotificationController

    @ObservationIgnored
    private let persistence: PlaybackPersistence

    @ObservationIgnored
    private let historyRecorder: PlaybackHistoryRecorder

    @ObservationIgnored
    private var loadGeneration = 0

    @ObservationIgnored
    private var beatAnalysisGeneration = 0

    @ObservationIgnored
    private var beatAnalysisTask:
        Task<Void, Never>?

    @ObservationIgnored
    private var isResolvingSource = false

    @ObservationIgnored
    private var hasRestoredPlayback = false

    @ObservationIgnored
    private var shouldResumeAfterInterruption = false

    @ObservationIgnored
    private var lastPersistedSecond = -1

    @ObservationIgnored
    private var playbackTimelineClock = PlaybackTimelineClock()

    @ObservationIgnored
    private var historySourceID: Int?

    @ObservationIgnored
    private var hasRecordedCurrentStart = false

    @ObservationIgnored
    private var isUsingDownloadedSource = false

    @ObservationIgnored
    private var currentLoadShouldAutoplay = false

    /// Streams given up on for this song since it last produced sound.
    /// Each one is a different source or tier, so the count is bounded by
    /// how many of those there are; the limit only guards against a loop.
    private var playbackRecoveryAttempts = 0

    private static let maximumPlaybackRecoveryAttempts = 12

    /// True once the current stream has produced sound. One that ends
    /// without having done so was not audio.
    @ObservationIgnored
    private var currentStreamHasPlayed = false

    /// How long the engine found the current stream to be, which for a
    /// preview clip is far shorter than the song.
    @ObservationIgnored
    private var currentStreamDuration: TimeInterval?

    private var currentPlaybackSource: PlaybackSource?

    @ObservationIgnored
    private var isLoadingAutoplayRecommendations = false

    /// Set while a seek issued during playback is still buffering. The
    /// engine reports that gap as loading; publishing it as a pause made
    /// every scrub flash the transport spinner and shrink the artwork.
    @ObservationIgnored
    private var isHoldingPlaybackStateForSeek = false

    @ObservationIgnored
    private var seekLoadingIndicatorTask: Task<Void, Never>?

    @ObservationIgnored
    private var qualitySwitchTask: Task<Void, Never>?

    @ObservationIgnored
    private var qualityNoticeTask: Task<Void, Never>?

    /// A stream fetched ahead of the reload that will play it.
    @ObservationIgnored
    private var preresolvedPlaybackSource: (songID: Int, source: PlaybackSource)?

    @ObservationIgnored
    private var resolvedAudioAvailability: [String: SongAudioAvailability] = [:]

    @ObservationIgnored
    private var audioAvailabilityFetches: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var playbackIssueDismissTask: Task<Void, Never>?

    @ObservationIgnored private var nextPreparation: NextPlaybackPreparation?
    @ObservationIgnored private var adoptedResolution: Task<SelectedPlaybackSource, Error>?
    @ObservationIgnored private var isCancellingPreparation = false

    #if DEBUG
    var debugNextPreparation: String {
        autoMixCoordinator.debugDeckPreparation ?? nextPreparation?.phase.rawValue ?? "idle"
    }
    #endif

    @ObservationIgnored
    private var nowPlayingLyricsSongID: Int?

    @ObservationIgnored
    private var nowPlayingLyrics: [LyricLine] = []

    @ObservationIgnored
    private var publishedNowPlayingLyricID: LyricLine.ID?

    @ObservationIgnored
    private var publishedLyricsLiveActivity:
        LyricsLiveActivityPublication?

    @ObservationIgnored
    private var listenTogetherSavedPlaybackOptions:
        ListenTogetherSavedPlaybackOptions?

    /// Set when the user changes shuffle or repeat after the room session
    /// starts, so the initial server snapshot cannot overwrite that choice.
    private var listenTogetherPlayModeTouched = false

    init(
        api: NeteaseAPI,
        settings: AppSettings,
        downloads: DownloadStore,
        lyricsNotificationController:
            LyricsNotificationController,
        persistence: PlaybackPersistence? = nil,
        onPlaybackRecorded: @escaping (Song) -> Void = { _ in }
    ) {
        self.api = api
        self.settings = settings
        self.downloads = downloads
        self.persistence = persistence ?? PlaybackPersistence()
        historyRecorder = PlaybackHistoryRecorder(
            api: api,
            settings: settings,
            onRecorded: onPlaybackRecorded
        )
        let engine = AudioPlaybackEngine(
            equalizerConfiguration: settings.equalizer.configuration
        )
        self.engine = engine
        let beatAnalyzer = AutoMixAudioAnalyzer()
        self.beatAnalyzer = beatAnalyzer
        autoMixCoordinator = AutoMixPlaybackCoordinator(
            downloads: downloads,
            engine: engine,
            analyzer: beatAnalyzer
        )
        nowPlayingSession = NowPlayingSession()
        lyricsLiveActivityController = LyricsLiveActivityController()
        self.lyricsNotificationController =
            lyricsNotificationController
        sleepTimer = PlaybackSleepTimer()
        bindEngine()
        bindAutoMixCoordinator()
        bindRemoteCommands()
        AudioPlaybackSessionConfigurator.preferredMixMode =
            settings.alwaysMixesWithOtherApps
            ? .mixWithOthers
            : .exclusive
        applyVolumeControlMode()
        sleepTimer.setExpirationHandler { [weak self] in
            guard let self else { return }
            self.setLocalPlaybackIntent(false)
            self.persistSnapshot()
        }
    }

    func restore() async {
        guard !hasRestoredPlayback else { return }
        hasRestoredPlayback = true
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled {
            playbackQueue.replace(with: MeloXDesignPreview.songs, startingAt: 0)
            currentSong = playbackQueue.currentSong
            duration = 214
            progress = 36
            reanchorPlaybackTimeline(to: progress, rate: 0)
            return
        }
        #endif
        guard let snapshot = persistence.load(), !snapshot.queue.isEmpty else {
            lyricsLiveActivityController.synchronize(with: nil)
            lyricsNotificationController.clear()
            return
        }

        playbackQueue.restore(
            songs: snapshot.queue,
            currentIndex: snapshot.currentIndex,
            isShuffled: snapshot.isShuffled,
            shuffledOrder: snapshot.shuffledOrder
        )
        currentSong = playbackQueue.currentSong
        duration = TimeInterval(currentSong?.durationMS ?? 0) / 1_000
        progress = clampedPlaybackPosition(snapshot.progress)
        reanchorPlaybackTimeline(to: progress, rate: 0)
        repeatMode = RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        volume = min(max(snapshot.volume, 0), 1)
        historySourceID = snapshot.historySourceID
        isHeartModeActive = snapshot.heartModeEnabled ?? false
        isAutoplayEnabled = snapshot.autoplayEnabled ?? false
        isAutoMixEnabled = snapshot.autoMixEnabled ?? false
        updateQueueModeIndicator(
            preferred: snapshot.queueModeIndicator.flatMap(
                QueuePlaybackModeIndicator.init(rawValue:)
            )
        )
        applyVolumeControlMode()

        await loadCurrentSong(
            autoplay: false,
            startAt: progress
        )
    }

    func beginListenTogetherSession() {
        guard listenTogetherSavedPlaybackOptions == nil else { return }
        listenTogetherSavedPlaybackOptions =
            ListenTogetherSavedPlaybackOptions(
                repeatMode: repeatMode,
                wasShuffled: isShuffled,
                autoplayEnabled: isAutoplayEnabled,
                autoMixEnabled: isAutoMixEnabled
            )
        isListenTogetherSessionActive = true
        listenTogetherPlayModeTouched = false
        repeatMode = .all
        if isShuffled {
            playbackQueue.toggleShuffle()
        }
        isAutoplayEnabled = false
        isAutoMixEnabled = false
        isHeartModeActive = false
        cancelNextPreparation()
        updateQueueModeIndicator()
        persistSnapshot()
    }

    func endListenTogetherSession() {
        guard let saved = listenTogetherSavedPlaybackOptions else {
            return
        }
        listenTogetherSavedPlaybackOptions = nil
        isListenTogetherSessionActive = false
        listenTogetherPlayModeTouched = false
        repeatMode = saved.repeatMode
        if isShuffled != saved.wasShuffled {
            playbackQueue.toggleShuffle()
        }
        isAutoplayEnabled = saved.autoplayEnabled
        isAutoMixEnabled = saved.autoMixEnabled
        updateQueueModeIndicator()
        persistSnapshot()
        prepareNextIfNeeded()
    }

    func synchronizeListenTogetherPlayback(
        songs: [Song],
        targetSongID: Int,
        progress targetProgress: TimeInterval,
        isPlaying shouldPlay: Bool,
        adoptsRoomPlayMode: Bool,
        playMode: String?
    ) async {
        guard !songs.isEmpty,
              let targetIndex = songs.firstIndex(where: {
                  $0.id == targetSongID
              }) else {
            return
        }

        isHeartModeActive = false
        if adoptsRoomPlayMode, !listenTogetherPlayModeTouched {
            applyListenTogetherPlayMode(playMode)
        }
        let queueChanged = songs.map(\.id) != queue.map(\.id)
        let songChanged = currentSong?.id != targetSongID

        if songChanged {
            recordCurrentPlayback()
        }
        if queueChanged || currentIndex != targetIndex {
            adoptListenTogetherQueue(
                songs: songs,
                targetIndex: targetIndex
            )
        }

        if !songChanged, isResolvingSource {
            currentLoadShouldAutoplay = shouldPlay
            let clamped = clampedPlaybackPosition(targetProgress)
            progress = clamped
            reanchorPlaybackTimeline(to: clamped, rate: 0)
            updateNowPlayingState()
            persistSnapshot()
            return
        }

        if songChanged || !engine.hasCurrentItem {
            hasRecordedCurrentStart = false
            await loadCurrentSong(
                autoplay: shouldPlay,
                startAt: max(targetProgress, 0)
            )
            return
        }

        currentSong = songs[targetIndex]
        nowPlayingSession.setSong(
            songs[targetIndex],
            duration: duration,
            queueIndex: currentIndex,
            queueCount: queue.count,
            lyricsDisplaySettings:
                nowPlayingLyricsDisplaySettings
        )

        if abs(estimatedProgress() - targetProgress) > 0.35 {
            seek(to: targetProgress, reportsToRoom: false)
        }

        currentLoadShouldAutoplay = shouldPlay
        if shouldPlay {
            dismissPlaybackIssue()
            engine.play()
        } else {
            engine.pause()
        }
        updateNowPlayingState()
        persistSnapshot()
    }

    func synchronizeListenTogetherQueue(songs: [Song]) {
        guard let currentSong,
              let index = songs.firstIndex(where: { $0.id == currentSong.id }),
              songs.map(\.id) != queue.map(\.id) else { return }
        adoptListenTogetherQueue(songs: songs, targetIndex: index)
        nowPlayingSession.setSong(
            currentSong,
            duration: duration,
            queueIndex: currentIndex,
            queueCount: queue.count,
            lyricsDisplaySettings: nowPlayingLyricsDisplaySettings
        )
        updateNowPlayingState()
        persistSnapshot()
    }

    private func adoptListenTogetherQueue(
        songs: [Song],
        targetIndex: Int
    ) {
        let queueChanged = songs.map(\.id) != queue.map(\.id)
        if queueChanged {
            cancelNextPreparation()
            playbackQueue.replace(
                with: songs,
                startingAt: targetIndex
            )
            historySourceID = nil
        } else if currentIndex != targetIndex {
            _ = playbackQueue.select(index: targetIndex)
        }
    }

    private func applyListenTogetherPlayMode(_ playMode: String?) {
        guard isListenTogetherSessionActive,
              let mode = playMode?.uppercased() else {
            return
        }
        if mode.contains("SINGLE") {
            repeatMode = .one
        } else if mode.contains("LOOP") {
            repeatMode = .all
        } else {
            repeatMode = .off
        }
        updateQueueModeIndicator()
    }

    func play(
        _ song: Song,
        in songs: [Song]? = nil,
        sourceID: Int? = nil,
        startAt: TimeInterval = 0
    ) async {
        let formerQueueIDs = listenTogetherDisplaySongIDs
        recordCurrentPlayback()
        isHeartModeActive = false
        if let songs, !songs.isEmpty {
            let index = songs.firstIndex(where: { $0.id == song.id }) ?? 0
            playbackQueue.replace(with: songs, startingAt: index)
            historySourceID = sourceID
        } else if let existingIndex = queue.firstIndex(where: { $0.id == song.id }) {
            _ = playbackQueue.select(index: existingIndex)
        } else {
            playbackQueue.replace(with: [song], startingAt: 0)
            historySourceID = sourceID
        }
        hasRecordedCurrentStart = false
        let maximumPosition = TimeInterval(song.durationMS) / 1_000
        let playbackPosition = maximumPosition > 0
            ? max(0, min(startAt, maximumPosition))
            : max(0, startAt)
        await loadCurrentSong(
            autoplay: true,
            startAt: playbackPosition,
            reportsToRoom: true,
            queueChanged: formerQueueIDs != listenTogetherDisplaySongIDs
        )
    }

    func playAll(_ songs: [Song], sourceID: Int? = nil) async {
        await replaceQueueAndPlay(
            songs,
            sourceID: sourceID,
            activatesHeartMode: false
        )
    }

    func playHeartMode(
        playlistID: Int,
        seedSongID: Int
    ) async throws {
        let songs = try await api.intelligenceModeSongs(
            seedSongID: seedSongID,
            playlistID: playlistID
        )
        try Task.checkCancellation()
        await replaceQueueAndPlay(
            songs,
            sourceID: playlistID,
            activatesHeartMode: true
        )
    }

    func disableHeartMode() {
        guard isHeartModeActive else { return }
        isHeartModeActive = false
        persistSnapshot()
    }

    private func replaceQueueAndPlay(
        _ songs: [Song],
        sourceID: Int?,
        activatesHeartMode: Bool
    ) async {
        guard !songs.isEmpty else { return }
        recordCurrentPlayback()
        let queueChanged = songs.map(\.id) != listenTogetherDisplaySongIDs
        playbackQueue.replace(with: songs, startingAt: 0)
        historySourceID = sourceID
        isHeartModeActive = activatesHeartMode
        hasRecordedCurrentStart = false
        await loadCurrentSong(autoplay: true, reportsToRoom: true, queueChanged: queueChanged)
    }

    func togglePlayback() {
        guard currentSong != nil else { return }
        if isLoading || engine.hasCurrentItem {
            let shouldPlay = isLoading ? !currentLoadShouldAutoplay : !isPlaying
            setLocalPlaybackIntent(shouldPlay)
        } else {
            Task { @MainActor [weak self] in
                await self?.retry()
            }
        }
    }

    private var transportStamp: (generation: Int, index: Int, songID: Int?, seek: Int, intent: Int) {
        (loadGeneration, currentIndex, currentSong?.id, seekRevision, transportRevision)
    }

    private func setLocalPlaybackIntent(_ shouldPlay: Bool) {
        transportRevision &+= 1
        currentLoadShouldAutoplay = shouldPlay
        if shouldPlay {
            dismissPlaybackIssue()
            engine.play()
        } else {
            engine.pause()
            persistSnapshot()
        }
        updateNowPlayingState()
        onListenTogetherTransport?(shouldPlay ? .play : .pause, currentSong?.id)
    }

    func retry() async {
        guard currentSong != nil else { return }
        playbackRecoveryAttempts = 0
        await loadCurrentSong(
            autoplay: true,
            startAt: estimatedProgress(),
            reportsToRoom: true
        )
    }

    func dismissPlaybackIssue() {
        playbackIssueDismissTask?.cancel()
        playbackIssueDismissTask = nil
        playbackIssue = nil
    }

    /// Tells the listener a song could not be played, for a few seconds.
    private func reportPlaybackIssue(_ issue: PlaybackIssue) {
        playbackIssue = issue
        UIAccessibility.post(
            notification: .announcement,
            argument: issue.message
        )
        playbackIssueDismissTask?.cancel()
        playbackIssueDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  self?.playbackIssue?.id == issue.id else {
                return
            }
            self?.playbackIssue = nil
        }
    }

    /// A notice about one song has nothing left to say once that song is
    /// loading or playing again.
    private func clearPlaybackIssue(forSongID songID: Int?) {
        guard let issue = playbackIssue, issue.songID == songID else {
            return
        }
        dismissPlaybackIssue()
    }

    /// The tiers worth offering in a quality picker. Apple Music's three
    /// options are always all there; of QQ's seven, those an enabled source
    /// declares, plus the current choice so it stays visible.
    func selectablePlaybackQualities(
        including selected: MusicQuality
    ) -> [MusicQuality] {
        if settings.usesAppleMusicQualityOptions {
            return MusicQuality.appleMusicOptions
        }
        let sourceQualities = api.sourcePlaybackQualities
        guard !sourceQualities.isEmpty else { return MusicQuality.allCases }
        return MusicQuality.allCases.filter {
            sourceQualities.contains($0) || $0 == selected
        }
    }

    /// Changes the standing quality for Wi-Fi or cellular in Settings.
    func selectPlaybackQuality(_ quality: MusicQuality, forCellularData: Bool? = nil) {
        let targetsCellularData = forCellularData ?? api.isCellularData
        let formerPreference = preferredPlaybackQuality
        // A choice made in Settings replaces one made in the player.
        api.clearSessionPlaybackQuality()
        if targetsCellularData {
            settings.cellularQuality = quality
        } else {
            settings.quality = quality
        }
        guard preferredPlaybackQuality != formerPreference else { return }
        applyPreferredQualityToCurrentSong(refreshingSource: false)
    }

    /// Switches between QQ's seven tiers and Apple Music's three options.
    func setUsesAppleMusicQualityOptions(_ isEnabled: Bool) {
        guard settings.usesAppleMusicQualityOptions != isEnabled else {
            return
        }
        let formerPreference = preferredPlaybackQuality
        if isEnabled {
            // A tier picked in the player may not be one of the three.
            api.clearSessionPlaybackQuality()
        }
        settings.usesAppleMusicQualityOptions = isEnabled
        guard preferredPlaybackQuality != formerPreference else { return }
        applyPreferredQualityToCurrentSong(refreshingSource: false)
    }

    /// Re-asks the sources for the standing quality, after the tier one of
    /// Apple Music's options stands for was changed in Settings.
    func refreshQualityMapping() {
        applyPreferredQualityToCurrentSong(refreshingSource: true)
    }

    /// Quality changes made from the Now Playing screen are scoped to this
    /// app session. The persistent defaults in Settings are untouched, so a
    /// fresh launch returns to the Wi-Fi/cellular quality configured there.
    func selectSessionPlaybackQuality(_ quality: MusicQuality) {
        // Choosing the standing tier again, for a song playing below it,
        // asks the sources once more instead of replaying their answer.
        let target = settings.requestedQuality(for: quality)
        let sameTarget = preferredPlaybackQuality == target
        let isRetry = selectedPlaybackQualityOption == quality
        api.setSessionPlaybackQuality(
            quality,
            forCellularData: api.isCellularData
        )
        guard !sameTarget || (isRetry && effectivePlaybackQuality != target) else { return }
        applyPreferredQualityToCurrentSong(refreshingSource: isRetry)
    }

    /// Brings the playing song in line with the chosen quality.
    ///
    /// The new stream is fetched while the current one keeps playing, and
    /// playback moves over only once a stream exists. A song without the
    /// chosen tier gets the next one down that QQ has; if that is what is
    /// already playing, nothing is touched.
    private func applyPreferredQualityToCurrentSong(refreshingSource: Bool) {
        guard let song = currentSong else { return }
        let preference = preferredPlaybackQuality

        guard api.isUsingSourceResolver, !song.mid.isEmpty else {
            let shouldAutoplay = isPlaying
                || (isLoading && currentLoadShouldAutoplay)
            let resumePosition = engine.currentPlaybackTime
                ?? estimatedProgress()
            seekRevision += 1
            let qualityChangeRevision = seekRevision
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentSong?.id == song.id else { return }
                let startPosition =
                    self.seekRevision == qualityChangeRevision
                    ? resumePosition
                    : self.estimatedProgress()
                await self.loadCurrentSong(
                    autoplay: shouldAutoplay,
                    startAt: startPosition
                )
            }
            return
        }

        qualitySwitchTask?.cancel()
        playbackQualityNotice = nil
        isSwitchingPlaybackQuality = true
        qualitySwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let availability = await audioAvailabilityForResolution(of: song)
            let source = try? await api.playbackSource(
                for: song,
                quality: preference,
                availability: availability,
                refreshingSource: refreshingSource
            )
            guard !Task.isCancelled else { return }
            qualitySwitchTask = nil
            isSwitchingPlaybackQuality = false
            guard currentSong?.id == song.id else { return }
            guard let source else {
                showPlaybackQualityNotice(
                    L10n.string("ui.player.quality_switch_failed")
                )
                return
            }

            if source.quality != preference {
                showPlaybackQualityNotice(
                    L10n.format(
                        "ui.player.quality_unavailable",
                        preference.title
                    )
                )
            }
            // The song is already playing the tier it would be moved to.
            if source.quality == effectivePlaybackQuality,
               engine.hasCurrentItem {
                return
            }

            preresolvedPlaybackSource = (song.id, source)
            let shouldAutoplay = isPlaying
                || (isLoading && currentLoadShouldAutoplay)
            let resumePosition = engine.currentPlaybackTime
                ?? estimatedProgress()
            seekRevision += 1
            await loadCurrentSong(
                autoplay: shouldAutoplay,
                startAt: resumePosition
            )
        }
    }

    private func showPlaybackQualityNotice(_ message: String) {
        playbackQualityNotice = message
        qualityNoticeTask?.cancel()
        qualityNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.playbackQualityNotice = nil
        }
    }

    private func cancelPlaybackQualitySwitch() {
        qualitySwitchTask?.cancel()
        qualitySwitchTask = nil
        isSwitchingPlaybackQuality = false
    }

    private func knownAudioAvailability(
        for song: Song
    ) -> SongAudioAvailability {
        if song.audioAvailability.isKnown {
            return song.audioAvailability
        }
        return resolvedAudioAvailability[song.mid] ?? .unknown
    }

    /// Asks QQ which encodings `song` has, for a song that came from a list
    /// without them. One request serves everyone who asks meanwhile.
    private func fetchAudioAvailabilityIfNeeded(for song: Song) {
        guard api.isUsingSourceResolver,
              !song.mid.isEmpty,
              !knownAudioAvailability(for: song).isKnown,
              audioAvailabilityFetches[song.mid] == nil else {
            return
        }
        audioAvailabilityFetches[song.mid] = Task { @MainActor [weak self] in
            guard let api = self?.api else { return }
            let detailedSong = try? await api.songDetail(mid: song.mid)
            guard let self else { return }
            audioAvailabilityFetches[song.mid] = nil
            guard let availability = detailedSong?.audioAvailability,
                  availability.isKnown else {
                return
            }
            resolvedAudioAvailability[song.mid] = availability
            if currentSong?.mid == song.mid {
                currentSongAudioAvailability = availability
            }
        }
    }

    /// Catalog sizes can corroborate an encoding, particularly branded mixes.
    /// Missing catalog data never excludes a tier from the source search.
    private func audioAvailabilityForResolution(
        of song: Song
    ) async -> SongAudioAvailability {
        fetchAudioAvailabilityIfNeeded(for: song)
        let deadline = ContinuousClock.now + .milliseconds(1_500)
        while audioAvailabilityFetches[song.mid] != nil,
              ContinuousClock.now < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return knownAudioAvailability(for: song)
    }

    func next() async {
        transportRevision &+= 1
        await moveToNext(recordingCurrentPlayback: true)
    }

    private func moveToNext(recordingCurrentPlayback: Bool) async {
        guard !queue.isEmpty else { return }
        let stamp = transportStamp
        if !playbackQueue.canMove(
            by: 1,
            wraps: repeatMode == .all
        ), isAutoplayEnabled {
            await appendAutoplayRecommendationsIfNeeded()
            guard transportStamp == stamp, !Task.isCancelled else { return }
        }
        if recordingCurrentPlayback {
            recordCurrentPlayback()
        }
        let prepared = currentNextPreparation(checkFile: true)
        if let prepared, let selected = prepared.selected,
           prepared.phase == .buffering || prepared.phase == .ready,
           engine.promoteStandby(token: prepared.token, autoplay: true) {
            // Trust the deck, not the scheduling of our ready notification.
            if prepared.phase == .buffering {
                rigTrace("next", "ready token=\(prepared.token) to=\(prepared.key.incomingID)")
            }
            // The engine swapped synchronously. Commit before its first incoming callback.
            commitPreparedNext(prepared, selected: selected, kind: "standby", reportsToRoom: true)
            return
        }
        guard playbackQueue.move(by: 1, wraps: repeatMode == .all) else {
            stopAtQueueEnd()
            return
        }
        hasRecordedCurrentStart = false
        await loadCurrentSong(autoplay: true, reportsToRoom: true, taking: prepared)
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if settings.previousRestartsCurrentSong, progress > 5 {
            seek(to: 0)
            return
        }
        guard playbackQueue.canMove(by: -1, wraps: repeatMode == .all) else {
            seek(to: 0)
            return
        }
        recordCurrentPlayback()
        guard playbackQueue.move(by: -1, wraps: repeatMode == .all) else { return }
        hasRecordedCurrentStart = false
        await loadCurrentSong(autoplay: true, reportsToRoom: true)
    }

    func playFromQueue(at index: Int) async {
        guard queue.indices.contains(index) else { return }
        recordCurrentPlayback()
        guard playbackQueue.select(index: index) else { return }
        hasRecordedCurrentStart = false
        await loadCurrentSong(autoplay: true, reportsToRoom: true)
    }

    func addToPlaybackQueue(_ song: Song) {
        cancelNextPreparation()
        playbackQueue.append(song)
        onListenTogetherQueueEdit?()
        persistSnapshot()
        prepareNextIfNeeded()
    }

    func playNext(_ song: Song) async {
        guard currentSong != nil, !queue.isEmpty else {
            await play(song)
            return
        }

        cancelNextPreparation()
        playbackQueue.insertNext(song)
        onListenTogetherQueueEdit?()
        persistSnapshot()
        prepareNextIfNeeded()
    }

    func moveUpcomingQueueItems(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        cancelNextPreparation()
        let previousIDs = listenTogetherDisplaySongIDs
        playbackQueue.moveUpcomingSongs(
            fromOffsets: source,
            toOffset: destination,
            wraps: repeatMode == .all
        )
        if listenTogetherDisplaySongIDs != previousIDs {
            onListenTogetherQueueEdit?()
        }
        persistSnapshot()
        prepareNextIfNeeded()
    }

    func seek(to seconds: TimeInterval, reportsToRoom: Bool = true) {
        let clamped = clampedPlaybackPosition(seconds)
        cancelNextPreparation()
        progress = clamped
        reanchorPlaybackTimeline(to: clamped, rate: 0)
        seekRevision += 1
        holdPlaybackStateForSeekIfNeeded()
        engine.seek(to: clamped)
        if reportsToRoom {
            onListenTogetherTransport?(.progress, currentSong?.id)
        }
        updateNowPlayingState(
            forceNowPlayingLyrics: true,
            forceLyricsLiveActivity: true
        )
        lastPersistedSecond = Int(clamped)
        persistence.saveProgress(clamped)
    }

    private func holdPlaybackStateForSeekIfNeeded() {
        seekLoadingIndicatorTask?.cancel()
        seekLoadingIndicatorTask = nil
        guard isPlaying else {
            isHoldingPlaybackStateForSeek = false
            return
        }

        isHoldingPlaybackStateForSeek = true
        // A slow seek still has to show that it is buffering.
        seekLoadingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, self.isHoldingPlaybackStateForSeek else {
                return
            }
            self.isLoading = true
        }
    }

    private func endSeekPlaybackStateHold() {
        isHoldingPlaybackStateForSeek = false
        seekLoadingIndicatorTask?.cancel()
        seekLoadingIndicatorTask = nil
    }

    func setNowPlayingLyrics(_ lyrics: [LyricLine], for songID: Int?) {
        guard let songID, currentSong?.id == songID else { return }
        nowPlayingLyricsSongID = songID
        nowPlayingLyrics = lyrics
        updateNowPlayingLyricMetadata()
        updateLyricsLiveActivity()
        updateLyricsNotification()
    }

    func applySystemNowPlayingLyricsPreference() {
        updateNowPlayingLyricMetadata(force: true)
    }

    func applyLyricsLiveActivityPreference() {
        updateLyricsLiveActivity(force: true)
    }

    func applyLyricsNotificationPreference() {
        updateLyricsNotification(force: true)
    }

    func refreshLyricsNotification() {
        updateLyricsNotification()
    }

    func presentLyricsNotificationPreview() {
        let song = currentSong
        let lyrics = currentSongLyrics
        lyricsNotificationController.presentPreview(
            song: song,
            lyrics: lyrics,
            playbackTime:
                estimatedProgress()
                    + settings.effectiveLyricsAdvanceTime(
                        for: lyrics
                    )
        )
    }

    func refreshLyricsLiveActivity() {
        updateLyricsLiveActivity(force: true)
    }

    func estimatedProgress(at date: Date = Date()) -> TimeInterval {
        playbackTimelineClock.position(
            at: date,
            duration: playbackDurationLimit
        )
    }

    private var playbackDurationLimit: TimeInterval {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return TimeInterval(currentSong?.durationMS ?? 0) / 1_000
    }

    private func clampedPlaybackPosition(
        _ position: TimeInterval
    ) -> TimeInterval {
        let normalized = position.isFinite
            ? max(position, 0)
            : 0
        let maximum = playbackDurationLimit
        guard maximum.isFinite, maximum > 0 else {
            return normalized
        }
        return min(normalized, maximum)
    }

    private func reanchorPlaybackTimeline(
        to position: TimeInterval,
        rate: Double,
        at date: Date = Date()
    ) {
        playbackTimelineClock.reanchor(
            to: position,
            rate: rate,
            at: date
        )
    }

    func beatDebugSnapshot(
        at date: Date = Date()
    ) -> PlaybackBeatDebugSnapshot? {
        currentBeatTimeline?.debugSnapshot(
            at: estimatedProgress(at: date)
        )
    }

    func clearCurrentSongBeatAnalysis() {
        resetBeatAnalysis()
    }

    func clearPlaybackAnalysisCache() async {
        cancelNextPreparation()
        resetBeatAnalysis()
        await beatAnalyzer.clearCache()
        scheduleBeatAnalysisIfNeeded()
        prepareNextIfNeeded()
    }

    @discardableResult
    func analyzeCurrentSongBeats() async -> PlaybackBeatTimeline? {
        guard let song = currentSong,
              !song.isPodcastProgram,
              let source = currentPlaybackSource else {
            currentBeatTimeline = nil
            beatAnalysisStatus = .idle
            return nil
        }
        if let currentBeatTimeline {
            return currentBeatTimeline
        }
        if case .analyzing = beatAnalysisStatus {
            return nil
        }

        beatAnalysisGeneration += 1
        let generation = beatAnalysisGeneration
        let songID = song.id
        beatAnalysisStatus = .analyzing
        let request = AutoMixAnalysisRequest(
            songID: songID,
            source: source,
            duration: max(
                duration,
                TimeInterval(song.durationMS) / 1_000
            ),
            isDownloaded: isUsingDownloadedSource
        )

        do {
            let analysis = try await beatAnalyzer.analyzeFullTrack(
                request
            )
            try Task.checkCancellation()
            guard generation == beatAnalysisGeneration,
                  currentSong?.id == songID,
                  currentPlaybackSource == source else {
                return nil
            }
            guard let timeline = PlaybackBeatTimeline(
                analysis: analysis
            ) else {
                throw AutoMixAnalysisError
                    .invalidModelOutput
            }
            currentBeatTimeline = timeline
            beatAnalysisStatus = .ready(
                bpm: timeline.bpm,
                confidence: timeline.confidence
            )
            return timeline
        } catch is CancellationError {
            guard generation == beatAnalysisGeneration else {
                return nil
            }
            restoreBeatAnalysisStatus()
            return nil
        } catch {
            guard generation == beatAnalysisGeneration,
                  currentSong?.id == songID,
                  currentPlaybackSource == source else {
                return nil
            }
            beatAnalysisStatus = .failed(
                message: error.localizedDescription
            )
            Self.beatAnalysisLogger.error(
                "Beat analysis failed for song \(songID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func resetBeatAnalysis() {
        beatAnalysisTask?.cancel()
        beatAnalysisTask = nil
        beatAnalysisGeneration += 1
        currentBeatTimeline = nil
        beatAnalysisStatus = .idle
    }

    private func scheduleBeatAnalysisIfNeeded() {
        guard settings.playerBackgroundStyle
            == .flowingLight,
            settings
                .playerBackgroundBeatEffectsEnabled,
            currentSong?.isPodcastProgram == false,
            currentPlaybackSource != nil,
            currentBeatTimeline == nil else {
            return
        }
        if case .analyzing = beatAnalysisStatus {
            return
        }

        beatAnalysisTask?.cancel()
        beatAnalysisTask = Task {
            [weak self] in
            await self?.analyzeCurrentSongBeats()
        }
    }

    private func restoreBeatAnalysisStatus() {
        if let currentBeatTimeline {
            beatAnalysisStatus = .ready(
                bpm: currentBeatTimeline.bpm,
                confidence:
                    currentBeatTimeline.confidence
            )
        } else {
            beatAnalysisStatus = .idle
        }
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        applyVolumeControlMode()
        persistSnapshot()
    }

    func applyVolumeControlMode() {
        let effectiveVolume = settings.playerVolumeControlMode == .independent
            ? volume
            : 1
        engine.setVolume(effectiveVolume)
    }

    func applyEqualizerSettings() {
        engine.setEqualizerConfiguration(settings.equalizer.configuration)
    }

    func cycleRepeatMode() {
        if isListenTogetherSessionActive {
            listenTogetherPlayModeTouched = true
        }
        cancelNextPreparation()
        switch repeatMode {
        case .off:
            repeatMode = .all
            queueModeIndicator = .repeatAll
        case .all:
            repeatMode = .one
            queueModeIndicator = .repeatOne
        case .one:
            repeatMode = .off
            updateQueueModeIndicator()
        }
        persistSnapshot()
    }

    func toggleShuffle() {
        if isListenTogetherSessionActive {
            listenTogetherPlayModeTouched = true
        }
        cancelNextPreparation()
        playbackQueue.toggleShuffle()
        if isShuffled {
            queueModeIndicator = .shuffle
        } else {
            updateQueueModeIndicator()
        }
        persistSnapshot()
    }

    func toggleAutoplay() {
        guard !isListenTogetherSessionActive else { return }
        isAutoplayEnabled.toggle()
        if isAutoplayEnabled {
            queueModeIndicator = .autoplay
        } else {
            updateQueueModeIndicator()
        }
        persistSnapshot()
        guard isAutoplayEnabled else { return }

        Task { @MainActor [weak self] in
            await self?.appendAutoplayRecommendationsIfNeeded()
        }
    }

    func toggleAutoMix() {
        guard !isListenTogetherSessionActive else { return }
        setAutoMixEnabled(!isAutoMixEnabled)
    }

    func setAutoMixEnabled(_ isEnabled: Bool) {
        guard !isListenTogetherSessionActive else { return }
        guard isAutoMixEnabled != isEnabled else { return }
        isAutoMixEnabled = isEnabled
        if isEnabled {
            queueModeIndicator = .autoMix
        } else {
            updateQueueModeIndicator()
            cancelNextPreparation()
        }
        persistSnapshot()
        if isEnabled {
            prepareNextIfNeeded()
        }
    }

    func resetAutoMixPreference() {
        if let saved = listenTogetherSavedPlaybackOptions {
            listenTogetherSavedPlaybackOptions =
                ListenTogetherSavedPlaybackOptions(
                    repeatMode: saved.repeatMode,
                    wasShuffled: saved.wasShuffled,
                    autoplayEnabled: saved.autoplayEnabled,
                    autoMixEnabled: false
                )
            isAutoMixEnabled = false
            cancelNextPreparation()
            persistSnapshot()
            return
        }

        setAutoMixEnabled(false)
    }

    func applyAutoMixSettings() {
        cancelNextPreparation()
        persistSnapshot()
        guard isAutoMixEnabled else { return }
        prepareNextIfNeeded()
    }

    private func loadCurrentSong(
        autoplay: Bool,
        startAt: TimeInterval = 0,
        reportsToRoom: Bool = false,
        queueChanged: Bool = false,
        taking prepared: NextPlaybackPreparation? = nil
    ) async {
        guard let song = playbackQueue.currentSong else { return }
        rigTrace("player", "load \(song.name) startAt=\(startAt) autoplay=\(autoplay)")
        let formerSongID = currentSong?.id
        if song.id != formerSongID || reportsToRoom {
            playbackRecoveryAttempts = 0
        }
        cancelPlaybackQualitySwitch()
        adoptedResolution?.cancel()
        adoptedResolution = prepared?.resolution
        cancelNextPreparation(keepingResolution: prepared)
        loadGeneration += 1
        let generation = loadGeneration
        defer {
            if generation == loadGeneration { adoptedResolution = nil }
        }
        // Publish play intent before unload and before `currentSong` changes.
        // Listen-together observes both, and the new item is not playing yet.
        currentLoadShouldAutoplay = autoplay
        isResolvingSource = true
        endSeekPlaybackStateHold()
        isLoading = true
        // Unloading can publish the outgoing deck's final clock sample.
        // Finish those callbacks before initializing the incoming song's timeline.
        engine.unload()
        currentSong = song
        let cachedDetailedSong = detailedPlaybackSongs[song.id]
        resolveCurrentSongAudioAvailability(
            for: song,
            generation: generation
        )
        resetBeatAnalysis()
        duration = TimeInterval(song.durationMS) / 1_000
        let playbackStartPosition = clampedPlaybackPosition(startAt)
        progress = playbackStartPosition
        reanchorPlaybackTimeline(
            to: playbackStartPosition,
            rate: 0
        )
        isPlaying = false
        isUsingDownloadedSource = false
        currentPlaybackSource = nil
        currentStreamHasPlayed = false
        currentStreamDuration = nil
        effectivePlaybackQuality = nil
        clearPlaybackIssue(forSongID: song.id)
        if nowPlayingLyricsSongID != song.id {
            nowPlayingLyricsSongID = nil
            nowPlayingLyrics = []
            publishedNowPlayingLyricID = nil
        }
        nowPlayingSession.setSong(
            song,
            duration: duration,
            queueIndex: currentIndex,
            queueCount: queue.count,
            lyricsDisplaySettings: nowPlayingLyricsDisplaySettings
        )
        updateNowPlayingState()
        persistSnapshot()
        if reportsToRoom {
            onListenTogetherTransport?(.goTo, formerSongID)
        }
        if queueChanged {
            onListenTogetherQueueEdit?()
        }

        do {
            let selected = try await playbackSourceRetryingTransientFailure(
                for: song, cachedDetailedSong: cachedDetailedSong,
                generation: generation, taking: prepared
            )
            guard generation == loadGeneration, currentSong?.id == song.id else { return }
            let source = selected.source
            isResolvingSource = false
            isUsingDownloadedSource = selected.isDownloaded
            currentPlaybackSource = source
            effectivePlaybackQuality = source.quality
            let shouldAutoplay = currentLoadShouldAutoplay
            let resolvedStartPosition = estimatedProgress()
            rigTrace("player", "resolved \(source.format ?? "?") \(String(describing: source.quality)) file=\(source.url.isFileURL); engine.load startAt=\(resolvedStartPosition) autoplay=\(shouldAutoplay)")
            await engine.load(
                source,
                startAt: resolvedStartPosition,
                autoplay: shouldAutoplay
            )
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            isResolvingSource = false
            isLoading = false
            updateNowPlayingState()
        } catch {
            guard generation == loadGeneration, currentSong?.id == song.id else { return }
            rigTrace("player", "load failed id=\(song.id)")
            isResolvingSource = false
            isLoading = false
            isPlaying = false
            updateNowPlayingState()
            persistSnapshot()

            // Without a connection every song would fail the same way.
            // Skipping through the queue would only lose the listener's
            // place in it.
            guard api.isNetworkAvailable else {
                reportPlaybackIssue(PlaybackIssue(offlineFor: song))
                return
            }
            consecutiveSourceFailures += 1
            reportPlaybackIssue(PlaybackIssue(song: song, error: error))

            // 洛雪源解析失败时提示并自动跳下一首；连续失败到队列长度后停止，
            // 避免在全部歌曲都不可解析时无限循环。
            guard consecutiveSourceFailures < max(queue.count, 1) else {
                return
            }
            let failedAt = transportStamp
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, transportStamp == failedAt,
                  currentLoadShouldAutoplay else { return }
            await moveToNext(recordingCurrentPlayback: false)
        }
    }

    /// `/api/song/enhance/player/url/v1` sometimes returns HTTP 200 with a null
    /// URL on the first try. The app treats that as a copyright/region error.
    /// Retry only this song, before showing the alert or starting audio.
    private func playbackSourceRetryingTransientFailure(
        for song: Song,
        cachedDetailedSong: Song?,
        generation: Int,
        taking prepared: NextPlaybackPreparation?
    ) async throws -> SelectedPlaybackSource {
        var borrowed = prepared
        var qualitySwitch = preresolvedPlaybackSource
        preresolvedPlaybackSource = nil
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            let policy = selectionPolicy(for: song)
            do {
                let selected: SelectedPlaybackSource
                var consumed: NextPlaybackPreparation?
                if let prepared = borrowed, prepared.key.policy == policy {
                    borrowed = nil
                    selected = try await prepared.resolution.value
                    consumed = prepared
                } else if let change = qualitySwitch, change.songID == song.id {
                    qualitySwitch = nil
                    selected = SelectedPlaybackSource(source: change.source, isDownloaded: false)
                } else {
                    borrowed?.resolution.cancel()
                    borrowed = nil
                    selected = try await selectPlaybackSource(for: song, policy: policy, cachedDetailedSong: cachedDetailedSong)
                }
                try Task.checkCancellation()
                guard generation == loadGeneration else { throw CancellationError() }
                guard policy == selectionPolicy(for: song) else { continue }
                if let consumed {
                    guard canReuse(selected, for: song, policy: policy) else { continue }
                    rigTrace("next", "handoff kind=source token=\(consumed.token) from=\(consumed.key.outgoingID) to=\(song.id)")
                }
                return selected
            } catch {
                try Task.checkCancellation()
                guard generation == loadGeneration else { throw CancellationError() }
                // A revision can cancel the resolver itself. Retry the *new* policy.
                guard policy == selectionPolicy(for: song) else { continue }
                attempt += 1
                guard attempt < 3, Self.isRetryablePlaybackSourceError(error) else { throw error }
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    private func selectionPolicy(for song: Song) -> PlaybackSelectionPolicy {
        PlaybackSelectionPolicy(
            quality: api.playbackQuality, hasSessionQuality: api.hasSessionPlaybackQuality,
            isCellular: api.isCellularData, isOnline: api.isNetworkAvailable,
            sourceRevision: api.sourceConfigurationRevision,
            downloadedAt: downloads.downloads.first { $0.id == song.id }?.downloadedAt
        )
    }

    /// Pure with respect to active playback. Foreground, ordinary standby and AutoMix
    /// use the same download priority and the tier actually returned by the resolver.
    private func selectPlaybackSource(
        for song: Song, policy: PlaybackSelectionPolicy, cachedDetailedSong: Song?
    ) async throws -> SelectedPlaybackSource {
        try Task.checkCancellation()
        let local = downloads.localPlaybackSource(songID: song.id)
        if let local, !api.isUsingSourceResolver || song.mid.isEmpty || !policy.hasSessionQuality || local.quality == policy.quality {
            return SelectedPlaybackSource(source: local, isDownloaded: true)
        }
        do {
            let stream: PlaybackSource
            if !api.isUsingSourceResolver, let cachedDetailedSong {
                stream = try await api.playbackSource(for: cachedDetailedSong)
            } else if !song.mid.isEmpty {
                let availability = await audioAvailabilityForResolution(of: song)
                try Task.checkCancellation()
                stream = try await api.playbackSource(for: song, quality: policy.quality, availability: availability)
            } else {
                stream = try await api.playbackSource(id: song.id)
            }
            try Task.checkCancellation()
            if let local, stream.quality != policy.quality,
               LXQualityMapping.rank(of: stream.quality) <= LXQualityMapping.rank(of: local.quality) {
                return SelectedPlaybackSource(source: local, isDownloaded: true)
            }
            return SelectedPlaybackSource(source: stream, isDownloaded: false)
        } catch {
            try Task.checkCancellation()
            guard !(error is CancellationError), let local else { throw error }
            return SelectedPlaybackSource(source: local, isDownloaded: true)
        }
    }

    private static func isRetryablePlaybackSourceError(_ error: Error) -> Bool {
        if error is LXPlaybackError {
            return false
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .noPlayableSource, .emptyResponse, .invalidResponse:
                return true
            case .server(let statusCode, _) where statusCode >= 500:
                return true
            case .server, .requestEncoding, .notLoggedIn:
                return false
            }
        }
        return error is URLError
    }

    private func handlePlaybackEnded() async {
        let stamp = transportStamp
        if await recoverFromTruncatedStream() { return }
        guard transportStamp == stamp, currentLoadShouldAutoplay, engine.expectsPlaybackToContinue else { return }
        rigTrace("next", "eof from=\(stamp.songID ?? 0)")
        recordCurrentPlayback(completed: true)
        if repeatMode == .one {
            hasRecordedCurrentStart = false
            seek(to: 0)
            engine.play()
            return
        }
        await moveToNext(recordingCurrentPlayback: false)
    }

    /// A stream that ends long before the song does was a preview clip or
    /// a file cut short, and one that ends without having made a sound was
    /// not audio at all. A source can return either in place of the song.
    /// Moving to the next song then would drop the rest of this one, so it
    /// carries on from where the stream gave out, on another stream.
    private func recoverFromTruncatedStream() async -> Bool {
        guard api.isUsingSourceResolver,
              !isUsingDownloadedSource,
              let song = currentSong,
              let source = currentPlaybackSource,
              playbackRecoveryAttempts
                < Self.maximumPlaybackRecoveryAttempts else {
            return false
        }
        let expected = TimeInterval(song.durationMS) / 1_000
        let endedAt = engine.currentPlaybackTime ?? estimatedProgress()
        let reached = max(endedAt, currentStreamDuration ?? 0)
        let endedSilent = !currentStreamHasPlayed
            && endedAt < expected - 5
        let endedShort = expected >= 30 && reached < expected * 0.6
        rigTrace("player", "ended at=\(endedAt) engineTime=\(String(describing: engine.currentPlaybackTime)) streamDuration=\(String(describing: currentStreamDuration)) expected=\(expected) silent=\(endedSilent) short=\(endedShort)")
        guard endedSilent || endedShort else {
            return false
        }
        playbackRecoveryAttempts += 1
        api.reportUnplayable(source, for: song)
        await loadCurrentSong(
            autoplay: currentLoadShouldAutoplay || endedShort,
            startAt: endedAt
        )
        return true
    }

    private func handleEngineFailure(_ error: Error) async {
        rigTrace("player", "engine failure \(error) resolving=\(isResolvingSource) attempts=\(playbackRecoveryAttempts)")
        if isResolvingSource {
            return
        }
        let isItemFailure: Bool
        if let playbackError = error as? AudioPlaybackError,
           case .itemFailed = playbackError {
            isItemFailure = true
        } else {
            isItemFailure = false
        }

        if isItemFailure,
           isUsingDownloadedSource,
           let song = currentSong {
            let resumePosition = estimatedProgress()
            let shouldAutoplay = currentLoadShouldAutoplay
            isUsingDownloadedSource = false
            downloads.discardInvalidDownload(songID: song.id)
            await loadCurrentSong(
                autoplay: shouldAutoplay,
                startAt: resumePosition
            )
            return
        }

        // Offline, another stream would fail the same way, and giving up
        // on this one would only lower the quality once the connection is
        // back. Playback waits where it is.
        if isItemFailure,
           !api.isNetworkAvailable,
           let song = currentSong {
            reportPlaybackIssue(PlaybackIssue(offlineFor: song))
            isLoading = false
            isPlaying = false
            updateNowPlayingState()
            engine.unload()
            persistSnapshot()
            return
        }

        if isItemFailure,
           playbackRecoveryAttempts
            < Self.maximumPlaybackRecoveryAttempts,
           let song = currentSong {
            playbackRecoveryAttempts += 1
            // The first failure may be the connection's, so the same stream
            // gets one more try. After that it is given up on, and the
            // sources are asked for another: a different source for the
            // same tier, or the next tier down.
            if let source = currentPlaybackSource,
               playbackRecoveryAttempts > 1 {
                api.reportUnplayable(source, for: song)
            }
            let resumePosition = estimatedProgress()
            let shouldAutoplay = currentLoadShouldAutoplay
            await loadCurrentSong(
                autoplay: shouldAutoplay,
                startAt: resumePosition
            )
            return
        }

        if let song = currentSong {
            reportPlaybackIssue(PlaybackIssue(song: song, error: error))
        }
        isLoading = false
        isPlaying = false
        updateNowPlayingState()

        if isItemFailure {
            engine.unload()
        }
        persistSnapshot()
    }

    private func stopAtQueueEnd() {
        cancelNextPreparation()
        engine.pause()
        engine.seek(to: 0)
        progress = 0
        reanchorPlaybackTimeline(to: 0, rate: 0)
        seekRevision += 1
        isPlaying = false
        isLoading = false
        currentLoadShouldAutoplay = false
        onListenTogetherTransport?(.pause, currentSong?.id)
        updateNowPlayingState()
        persistSnapshot()
    }

    private func bindEngine() {
        engine.onStateChanged = { [weak self] state in
            guard let self else { return }
            rigTrace("player", "engine \(state) at \(String(describing: self.engine.currentPlaybackTime))")
            switch state {
            case .idle:
                self.endSeekPlaybackStateHold()
                self.isPlaying = false
                if !self.isResolvingSource {
                    self.isLoading = false
                }
            case .loading:
                if !self.isHoldingPlaybackStateForSeek {
                    self.isPlaying = false
                    self.isLoading = true
                }
            case .paused:
                self.endSeekPlaybackStateHold()
                self.isPlaying = false
                if self.engine.expectsPlaybackToContinue {
                    self.isLoading = true
                    self.currentLoadShouldAutoplay = true
                } else {
                    self.isLoading = false
                }
            case .playing:
                self.endSeekPlaybackStateHold()
                self.isPlaying = true
                self.isLoading = false
                self.currentLoadShouldAutoplay = true
                self.currentStreamHasPlayed = true
                self.playbackRecoveryAttempts = 0
                self.consecutiveSourceFailures = 0
                self.clearPlaybackIssue(forSongID: self.currentSong?.id)
                self.recordCurrentPlaybackStartIfNeeded()
                self.scheduleBeatAnalysisIfNeeded()
                self.prepareNextIfNeeded()
            }
            self.updateNowPlayingState()
        }
        engine.onPlaybackClockChanged = { [weak self] sample in
            self?.handlePlaybackClockSample(sample)
        }
        engine.onDurationChanged = { [weak self] value in
            guard let self else { return }
            rigTrace("player", "engine duration \(value)")
            self.duration = value
            self.currentStreamDuration = value
            self.updateNowPlayingState()
        }
        engine.onPlaybackEnded = { [weak self] in
            guard let self else { return }
            let stamp = self.transportStamp
            Task { @MainActor in
                guard self.transportStamp == stamp, self.currentLoadShouldAutoplay,
                      self.engine.expectsPlaybackToContinue else { return }
                await self.handlePlaybackEnded()
            }
        }
        engine.onFailure = { [weak self] error in
            guard let self else { return }
            let stamp = self.transportStamp
            Task { @MainActor in
                guard self.transportStamp == stamp else { return }
                await self.handleEngineFailure(error)
            }
        }
        engine.onInterruptionBegan = { [weak self] event in
            self?.handleAudioInterruptionBegan(event)
        }
        engine.onInterruptionEnded = { [weak self] shouldResume in
            self?.handleAudioInterruptionEnded(shouldResume: shouldResume)
        }
        engine.onOutputDeviceDisconnected = { [weak self] in
            self?.shouldResumeAfterInterruption = false
        }
    }

    func applyBackgroundAudioMixPolicy() {
        AudioPlaybackSessionConfigurator.preferredMixMode =
            settings.alwaysMixesWithOtherApps
            ? .mixWithOthers
            : .exclusive
        let shouldContinue =
            isPlaying || engine.expectsPlaybackToContinue
        if engine.hasCurrentItem, shouldContinue {
            engine.resumeInPlace()
        }
        updateNowPlayingState()
    }

    private func handleAudioInterruptionBegan(
        _ event: AudioSessionInterruptionBegan
    ) {
        if AudioPlaybackSessionConfigurator.isApplyingConfiguration,
           !event.routeDisconnected, !event.wasSuspended {
            return
        }
        shouldResumeAfterInterruption =
            !event.routeDisconnected && isPlaying
        engine.pause()
    }

    private func handleAudioInterruptionEnded(shouldResume: Bool) {
        if shouldResume, shouldResumeAfterInterruption {
            engine.play()
        }
        shouldResumeAfterInterruption = false
    }

    private func handlePlaybackClockSample(
        _ sample: AudioPlaybackClockSample
    ) {
        let measuredProgress = clampedPlaybackPosition(
            sample.position
        )
        progress = measuredProgress
        reanchorPlaybackTimeline(
            to: measuredProgress,
            rate: sample.rate,
            at: sample.sampledAt
        )
        updateNowPlayingLyricMetadata()
        updateLyricsLiveActivity()
        updateLyricsNotification()
        let second = Int(measuredProgress)
        if second != lastPersistedSecond {
            lastPersistedSecond = second
            persistence.saveProgress(measuredProgress)
            prepareNextIfNeeded()
        } else if isAutoMixEnabled {
            prepareNextIfNeeded()
        }
    }

    /// Indices name occurrences (including duplicate IDs) within one queue revision.
    /// Check external inputs again at the actual handoff, not only on clock ticks.
    private func currentNextPreparation(checkFile: Bool = false) -> NextPlaybackPreparation? {
        guard let prepared = nextPreparation else { return nil }
        let key = prepared.key
        guard key.loadGeneration == loadGeneration, key.queueRevision == queueRevision,
              key.outgoingIndex == currentIndex, key.outgoingID == currentSong?.id,
              queue.indices.contains(key.incomingIndex), queue[key.incomingIndex].id == key.incomingID,
              key.repeatMode == repeatMode, key.autoMixEnabled == isAutoMixEnabled,
              prepared.isFresh else { return nil }
        let song = queue[key.incomingIndex]
        if let selected = prepared.selected, !canReuse(selected, for: song, policy: key.policy) { return nil }
        if checkFile, key.policy.downloadedAt != nil,
           downloads.localPlaybackSource(songID: song.id) == nil { return nil }
        return key.policy == selectionPolicy(for: song) ? prepared : nil
    }

    private func canReuse(_ selected: SelectedPlaybackSource, for song: Song, policy: PlaybackSelectionPolicy) -> Bool {
        guard selected.isFresh else { return false }
        let source = selected.source
        guard let revision = source.configurationRevision else { return true }
        guard revision == policy.sourceRevision else { return false }
        // A cached verified result may already have been old when we borrowed it.
        guard source.qualityVerified, let tier = source.quality else { return true }
        return api.sourceEvidence(for: song, quality: tier) == .verified
    }

    private func startNextPreparation(
        outgoing: Song, incoming: Song, at index: Int, usesAutoMix: Bool
    ) {
        let policy = selectionPolicy(for: incoming)
        let key = NextPlaybackPreparation.Key(
            loadGeneration: loadGeneration, queueRevision: queueRevision,
            outgoingIndex: currentIndex, outgoingID: outgoing.id,
            incomingIndex: index, incomingID: incoming.id,
            repeatMode: repeatMode, autoMixEnabled: isAutoMixEnabled, policy: policy
        )
        let resolution = Task { @MainActor in
            try await selectPlaybackSource(for: incoming, policy: policy, cachedDetailedSong: detailedPlaybackSongs[incoming.id])
        }
        let prepared = NextPlaybackPreparation(key: key, resolution: resolution)
        nextPreparation = prepared
        rigTrace("next", "prepare token=\(prepared.token) from=\(outgoing.id) to=\(incoming.id)")
        prepared.warmingTask = Task { @MainActor [weak self, weak prepared] in
            guard let self, let prepared else { return }
            defer { prepared.warmingTask = nil }
            do {
                let selected = try await resolution.value
                guard !Task.isCancelled, currentNextPreparation(checkFile: true) === prepared else { return }
                prepared.selected = selected
                prepared.phase = .resolved
                if usesAutoMix {
                    prepareNextIfNeeded()
                    return
                }
                prepared.phase = .buffering
                let ready = await engine.prepareStandby(selected.source, token: prepared.token)
                guard !Task.isCancelled, currentNextPreparation(checkFile: true) === prepared else { return }
                // An unsuccessful warm-up does not invalidate a good source or skip a song.
                prepared.phase = ready ? .ready : .resolved
                if ready { rigTrace("next", "ready token=\(prepared.token) to=\(incoming.id)") }
            } catch {
                guard !Task.isCancelled, nextPreparation === prepared else { return }
                prepared.phase = .failed
            }
        }
    }

    private func bindAutoMixCoordinator() {
        autoMixCoordinator.isCurrentPreparation = { [weak self] token in
            self?.currentNextPreparation(checkFile: true)?.token == token
        }
        autoMixCoordinator.onTransitionBegan = {
            [weak self] context, plan in
            guard let self,
                  context.outgoingSongID
                    == self.currentSong?.id else {
                return
            }
            self.autoMixTransitionKind = plan.kind
            self.autoMixIncomingSongName =
                context.incomingSong.name
            self.autoMixTransitionProgress = 0
        }
        autoMixCoordinator.onTransitionProgress = {
            [weak self] progress in
            guard let self,
                  self.autoMixTransitionProgress != nil else {
                return
            }
            self.autoMixTransitionProgress = progress
        }
        autoMixCoordinator.onTransitionCompleted = {
            [weak self] context in
            self?.completeAutoMixTransition(
                context: context
            )
        }
    }

    private func bindRemoteCommands() {
        nowPlayingSession.onPlay = { [weak self] in
            guard let self else { return }
            if self.engine.hasCurrentItem || self.isLoading {
                self.setLocalPlaybackIntent(true)
            } else {
                Task { @MainActor in await self.retry() }
            }
        }
        nowPlayingSession.onPause = { [weak self] in
            self?.setLocalPlaybackIntent(false)
        }
        nowPlayingSession.onNext = { [weak self] in
            Task { @MainActor in await self?.next() }
        }
        nowPlayingSession.onPrevious = { [weak self] in
            Task { @MainActor in await self?.previous() }
        }
        nowPlayingSession.onSeek = { [weak self] position in
            self?.seek(to: position)
        }
    }

    private func updateNowPlayingState(
        forceNowPlayingLyrics: Bool = false,
        forceLyricsLiveActivity: Bool = false
    ) {
        updateNowPlayingLyricMetadata(
            force: forceNowPlayingLyrics
        )
        updateLyricsLiveActivity(force: forceLyricsLiveActivity)
        updateLyricsNotification()
        nowPlayingSession.updatePlayback(
            position: progress,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func updateNowPlayingLyricMetadata(
        force: Bool = false
    ) {
        guard let song = currentSong else { return }
        let lyrics = currentSongLyrics
        let advanceTime = settings.effectiveLyricsAdvanceTime(
            for: lyrics
        )
        let highlightedLyricID = settings.systemNowPlayingLyricsEnabled
            ? LyricPlaybackTimeline.position(
                at: estimatedProgress() + advanceTime,
                in: lyrics
            ).highlightedLyricID
            : nil
        guard force
                || highlightedLyricID
                    != publishedNowPlayingLyricID else {
            return
        }

        let currentLyric = highlightedLyricID.flatMap { lyricID in
            lyrics.first(where: { $0.id == lyricID })
        }
        publishedNowPlayingLyricID = highlightedLyricID
        nowPlayingSession.updateCurrentLyric(
            currentLyric?.text,
            for: song,
            lyricsDisplaySettings: nowPlayingLyricsDisplaySettings
        )
    }

    private func updateLyricsLiveActivity(force: Bool = false) {
        guard let song = currentSong,
              shouldPresentLyricsLiveActivity else {
            publishLyricsLiveActivity(
                .inactive,
                snapshot: nil,
                force: force
            )
            return
        }
        guard settings.lyricsLiveActivityEnabled else {
            publishLyricsLiveActivity(
                .inactive,
                snapshot: nil,
                force: force
            )
            return
        }

        let lyrics = currentSongLyrics
        let adjustedProgress = estimatedProgress()
            + settings.effectiveLyricsAdvanceTime(for: lyrics)
        let position = LyricPlaybackTimeline.position(
            at: adjustedProgress,
            in: lyrics
        )
        let currentLyricIndex = position.highlightedLyricID.flatMap {
            lyricID in
            lyrics.firstIndex(where: { $0.id == lyricID })
        }
        let currentLyric = currentLyricIndex.map { lyrics[$0] }
        let nextLyric: LyricLine? = if let currentLyricIndex {
            lyrics.indices.contains(currentLyricIndex + 1)
                ? lyrics[currentLyricIndex + 1]
                : nil
        } else {
            lyrics.first
        }
        let preferences = LyricsLiveActivityPreferences(
            settings: settings
        )
        let displayText = LyricsLiveActivityFormatter.text(
            songTitle: song.name,
            songArtist: song.artistText,
            currentLyric: currentLyric?.text,
            preferences: preferences
        )
        let artworkURL = preferences.showsArtwork
            ? song.album?.artworkURL
            : nil
        let compactScrollDistance =
            lyricsLiveActivityCompactScrollDistance(
                text: displayText.compact,
                currentLyric: currentLyric,
                nextTransitionTime: position.nextTransitionTime,
                adjustedProgress: adjustedProgress,
                preferences: preferences
            )
        let signature = LyricsLiveActivityPublicationSignature(
            songID: song.id,
            currentLyricID: currentLyric?.id,
            nextLyricID: preferences.showsNextLyric
                ? nextLyric?.id
                : nil,
            isPlaying: isPlaying,
            title: displayText.title,
            subtitle: displayText.subtitle,
            compactText: displayText.compact,
            compactScrollDistancePoints:
                Int(compactScrollDistance.rounded()),
            artworkURL: artworkURL,
            preferences: preferences,
            durationMilliseconds: Int((duration * 1_000).rounded())
        )
        let snapshot = LyricsLiveActivitySnapshot(
            songID: song.id,
            title: displayText.title,
            subtitle: displayText.subtitle,
            compactText: displayText.compact,
            compactScrollDistance: compactScrollDistance,
            nextLyric: preferences.showsNextLyric
                ? nextLyric?.text
                : nil,
            artworkURL: artworkURL,
            presentation: preferences.presentation,
            isPlaying: isPlaying,
            playbackPosition: estimatedProgress(),
            duration: duration,
            staleDate: nil
        )
        publishLyricsLiveActivity(
            .content(signature),
            snapshot: snapshot,
            force: force
        )
    }

    private func updateLyricsNotification(force: Bool = false) {
        let lyrics = currentSongLyrics
        lyricsNotificationController.update(
            song: currentSong,
            lyrics: lyrics,
            playbackTime:
                estimatedProgress()
                    + settings.effectiveLyricsAdvanceTime(
                        for: lyrics
                    ),
            isPlaying: isPlaying,
            force: force
        )
    }

    private var currentSongLyrics: [LyricLine] {
        guard let songID = currentSong?.id,
              nowPlayingLyricsSongID == songID else {
            return []
        }
        return nowPlayingLyrics
    }

    private var shouldPresentLyricsLiveActivity: Bool {
        isPlaying || (isLoading && currentLoadShouldAutoplay)
    }

    private func publishLyricsLiveActivity(
        _ publication: LyricsLiveActivityPublication,
        snapshot: LyricsLiveActivitySnapshot?,
        force: Bool
    ) {
        guard force || publication != publishedLyricsLiveActivity else {
            return
        }
        publishedLyricsLiveActivity = publication
        lyricsLiveActivityController.synchronize(with: snapshot)
    }

    private func lyricsLiveActivityCompactScrollDistance(
        text: String,
        currentLyric: LyricLine?,
        nextTransitionTime: TimeInterval?,
        adjustedProgress: TimeInterval,
        preferences: LyricsLiveActivityPreferences
    ) -> Double {
        let pointSize = preferences.compactTextSize.pointSize
        guard preferences.scrollsCompactText,
              LyricsLiveActivityCompactLayout.requiresScrolling(
                text: text,
                pointSize: pointSize
              )
        else {
            return 0
        }

        guard let currentLyric else { return 0 }
        let startTime = currentLyric.time
        let elapsed = max(adjustedProgress - startTime, 0)
        let scrollDistance =
            LyricsLiveActivityCompactLayout
                .scrollDistanceToRevealEnd(
                    text: text,
                    pointSize: pointSize
                )
        guard scrollDistance > 0 else { return 0 }

        let configuredPause = max(
            preferences.scrollPause,
            0
        )
        let lineEndTime = nextTransitionTime
            ?? currentLyric.duration.map {
                currentLyric.time + $0
            }
        let timing: (pause: TimeInterval, speed: Double) = {
            guard let lineEndTime else {
                return (
                    configuredPause,
                    max(preferences.scrollSpeed, 1)
                )
            }

            let lineDuration = max(
                lineEndTime - currentLyric.time,
                0.25
            )
            let pause = min(
                configuredPause,
                lineDuration * 0.2
            )
            // ActivityKit updates are delivered asynchronously. Keep the
            // completed tail visible long enough for the last page to arrive
            // before the lyric transition.
            let endingHold = min(
                1.25,
                lineDuration * 0.25
            )
            let availableTravelTime = max(
                lineDuration - pause - endingHold,
                0.25
            )
            let requiredSpeed =
                scrollDistance / availableTravelTime
            return (
                pause,
                max(
                    max(preferences.scrollSpeed, requiredSpeed),
                    1
                )
            )
        }()

        let travelDistance = min(
            max(elapsed - timing.pause, 0) * timing.speed,
            scrollDistance
        )
        return travelDistance.rounded()
    }

    private var nowPlayingLyricsDisplaySettings:
        NowPlayingLyricsDisplaySettings {
        NowPlayingLyricsDisplaySettings(
            isEnabled:
                settings.systemNowPlayingLyricsEnabled
                && currentSong?.isPodcastProgram != true,
            titleFormat: settings.systemNowPlayingLyricsTitleFormat,
            subtitleFormat: settings.systemNowPlayingLyricsSubtitleFormat
        )
    }

    private func recordCurrentPlayback(completed: Bool = false) {
        guard hasRecordedCurrentStart,
              let currentSong,
              !currentSong.isPodcastProgram else {
            return
        }
        historyRecorder.recordPlaybackDuration(
            song: currentSong,
            sourceID: historySourceID,
            playbackTime: estimatedProgress(),
            completed: completed
        )
    }

    private func recordCurrentPlaybackStartIfNeeded() {
        guard !hasRecordedCurrentStart, let currentSong else { return }
        hasRecordedCurrentStart = true
        rigTrace("next", "playing id=\(currentSong.id)")
        guard !currentSong.isPodcastProgram else { return }
        historyRecorder.recordRecentPlayback(
            song: currentSong,
            sourceID: historySourceID
        )
        downloads.recordPlayback(currentSong)
    }

    private func persistSnapshot() {
        guard !queue.isEmpty else {
            persistence.clear()
            return
        }
        persistence.save(
            PlaybackSnapshot(
                queue: queue,
                currentIndex: currentIndex,
                progress: progress,
                repeatMode: repeatMode.rawValue,
                isShuffled: isShuffled,
                shuffledOrder: playbackQueue.persistedShuffleOrder,
                volume: volume,
                historySourceID: historySourceID,
                heartModeEnabled: isHeartModeActive,
                autoplayEnabled: isAutoplayEnabled,
                autoMixEnabled: isAutoMixEnabled,
                queueModeIndicator: queueModeIndicator?.rawValue
            )
        )
    }

    private func updateQueueModeIndicator(
        preferred: QueuePlaybackModeIndicator? = nil
    ) {
        if let preferred, isModeActive(preferred) {
            queueModeIndicator = preferred
            return
        }

        if repeatMode == .one {
            queueModeIndicator = .repeatOne
        } else if repeatMode == .all {
            queueModeIndicator = .repeatAll
        } else if isShuffled {
            queueModeIndicator = .shuffle
        } else if isAutoplayEnabled {
            queueModeIndicator = .autoplay
        } else if isAutoMixEnabled {
            queueModeIndicator = .autoMix
        } else {
            queueModeIndicator = nil
        }
    }

    private func isModeActive(
        _ mode: QueuePlaybackModeIndicator
    ) -> Bool {
        switch mode {
        case .shuffle:
            isShuffled
        case .repeatAll:
            repeatMode == .all
        case .repeatOne:
            repeatMode == .one
        case .autoplay:
            isAutoplayEnabled
        case .autoMix:
            isAutoMixEnabled
        }
    }

    private func appendAutoplayRecommendationsIfNeeded() async {
        guard isAutoplayEnabled,
              !isLoadingAutoplayRecommendations,
              playbackQueue.upcomingIndices(wraps: false).isEmpty,
              let currentSong,
              !currentSong.isPodcastProgram else {
            return
        }

        let generation = loadGeneration
        let revision = queueRevision
        isLoadingAutoplayRecommendations = true
        defer { isLoadingAutoplayRecommendations = false }

        do {
            let recommendations = try await api.similarSongs(
                song: currentSong
            )
            guard !Task.isCancelled, isAutoplayEnabled,
                  loadGeneration == generation, queueRevision == revision else { return }
            let existingSongIDs = Set(queue.map(\.id))
            let newSongs = recommendations.filter {
                !existingSongIDs.contains($0.id)
            }
            playbackQueue.append(
                contentsOf: Array(newSongs.prefix(25))
            )
            persistSnapshot()
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func prepareNextIfNeeded() {
        guard !isCancellingPreparation, !isResolvingSource,
              isPlaying, currentLoadShouldAutoplay, !isHoldingPlaybackStateForSeek,
              let outgoing = currentSong, let source = currentPlaybackSource else { return }
        let existing = currentNextPreparation()
        if existing == nil, nextPreparation != nil { cancelNextPreparation() }
        guard repeatMode != .one else { return }
        let remaining = playbackDurationLimit - estimatedProgress()
        // Ordinary ticks do not need to enumerate a long queue outside the window.
        if !isAutoMixEnabled, existing != nil || playbackDurationLimit <= 0 || remaining > 60 { return }
        guard let index = existing?.key.incomingIndex ?? upcomingQueueIndices.first else { return }
        let incoming = queue[index]
        let usesAutoMix = isAutoMixEnabled && !outgoing.isPodcastProgram && !incoming.isPodcastProgram
        let configuration = settings.autoMix.configuration
        if usesAutoMix {
            let mixRemaining = max(duration, TimeInterval(outgoing.durationMS) / 1_000) - estimatedProgress()
            guard configuration.mode == .smart || mixRemaining <= configuration.preloadLeadTime else { return }
        } else if playbackDurationLimit <= 0 || remaining > 60 { return }

        guard let prepared = existing else {
            startNextPreparation(outgoing: outgoing, incoming: incoming, at: index, usesAutoMix: usesAutoMix)
            return
        }
        if usesAutoMix, let selected = prepared.selected {
            autoMixCoordinator.prepareIfNeeded(
                token: prepared.token, outgoingSong: outgoing, outgoingSource: source,
                outgoingSourceIsDownloaded: isUsingDownloadedSource, outgoingDuration: duration,
                outgoingProgress: estimatedProgress(), incomingSong: incoming,
                incomingSource: selected, configuration: configuration
            )
        }
    }

    private func cancelNextPreparation(keepingResolution keeper: NextPlaybackPreparation? = nil) {
        isCancellingPreparation = true
        defer { isCancellingPreparation = false }
        if let prepared = nextPreparation {
            nextPreparation = nil
            prepared.warmingTask?.cancel()
            if prepared !== keeper { prepared.resolution.cancel() }
            if prepared.phase == .buffering || prepared.phase == .ready { engine.cancelStandby() }
        }
        autoMixTransitionProgress = nil
        autoMixTransitionKind = nil
        autoMixIncomingSongName = nil
        autoMixCoordinator.cancel()
    }

    private func completeAutoMixTransition(context: PreparedAutoMixContext) {
        guard let prepared = nextPreparation, context.token == prepared.token else { return }
        recordCurrentPlayback(completed: true)
        if currentNextPreparation(checkFile: true) === prepared, let selected = prepared.selected {
            commitPreparedNext(prepared, selected: selected, kind: "automix", reportsToRoom: false)
        } else {
            // The controller has already switched decks. A policy change in the last
            // fade frame must not leave stale audio playing under the outgoing title.
            let stamp = transportStamp
            cancelNextPreparation()
            engine.unload()
            Task { @MainActor in
                guard transportStamp == stamp, currentLoadShouldAutoplay else { return }
                await moveToNext(recordingCurrentPlayback: false)
            }
        }
    }

    /// Both kinds of deck handoff arrive here after the engine swap, with no await.
    private func commitPreparedNext(
        _ prepared: NextPlaybackPreparation, selected: SelectedPlaybackSource,
        kind: String, reportsToRoom: Bool
    ) {
        let key = prepared.key
        nextPreparation = nil
        _ = playbackQueue.select(index: key.incomingIndex)
        let song = queue[key.incomingIndex]
        rigTrace("next", "handoff kind=\(kind) token=\(prepared.token) from=\(key.outgoingID) to=\(song.id)")
        loadGeneration += 1
        cancelPlaybackQualitySwitch()
        endSeekPlaybackStateHold()
        currentSong = song
        resolveCurrentSongAudioAvailability(for: song, generation: loadGeneration)
        resetBeatAnalysis()
        currentPlaybackSource = selected.source
        effectivePlaybackQuality = selected.source.quality
        isUsingDownloadedSource = selected.isDownloaded
        currentLoadShouldAutoplay = engine.expectsPlaybackToContinue
        isResolvingSource = false
        isPlaying = engine.state == .playing
        isLoading = engine.state == .loading
        currentStreamHasPlayed = isPlaying
        currentStreamDuration = nil
        playbackRecoveryAttempts = 0
        consecutiveSourceFailures = 0
        duration = TimeInterval(song.durationMS) / 1_000
        progress = clampedPlaybackPosition(engine.currentPlaybackTime ?? 0)
        reanchorPlaybackTimeline(to: progress, rate: isPlaying ? 1 : 0)
        dismissPlaybackIssue()
        hasRecordedCurrentStart = false
        lastPersistedSecond = Int(progress)
        nowPlayingLyricsSongID = nil
        nowPlayingLyrics = []
        publishedNowPlayingLyricID = nil
        publishedLyricsLiveActivity = nil
        autoMixTransitionProgress = nil
        autoMixTransitionKind = nil
        autoMixIncomingSongName = nil
        nowPlayingSession.setSong(
            song, duration: duration, queueIndex: currentIndex, queueCount: queue.count,
            lyricsDisplaySettings: nowPlayingLyricsDisplaySettings
        )
        if isPlaying { recordCurrentPlaybackStartIfNeeded() }
        updateNowPlayingState(forceNowPlayingLyrics: true, forceLyricsLiveActivity: true)
        persistSnapshot()
        if reportsToRoom { onListenTogetherTransport?(.goTo, key.outgoingID) }
        scheduleBeatAnalysisIfNeeded()
        prepareNextIfNeeded()
    }

    private func resolveCurrentSongAudioAvailability(
        for song: Song,
        generation: Int
    ) {
        audioAvailabilityTask?.cancel()
        if api.isUsingSourceResolver {
            let known = knownAudioAvailability(for: song)
            currentSongAudioAvailability = known
            isResolvingCurrentSongAudioAvailability = false
            audioAvailabilityTask = nil
            // Lists that omit the file sizes leave the tiers unknown; the
            // song detail has them.
            fetchAudioAvailabilityIfNeeded(for: song)
            return
        }
        if let detailedSong = detailedPlaybackSongs[song.id] {
            currentSongAudioAvailability =
                detailedSong.audioAvailability
            isResolvingCurrentSongAudioAvailability = false
            audioAvailabilityTask = nil
            return
        }

        currentSongAudioAvailability = song.audioAvailability
        isResolvingCurrentSongAudioAvailability = true
        audioAvailabilityTask = Task { @MainActor [weak self] in
            guard let api = self?.api else { return }
            let detailedSong: Song?
            do {
                detailedSong = try await api.songDetails(
                    ids: [song.id]
                ).first
            } catch is CancellationError {
                return
            } catch {
                detailedSong = nil
            }
            guard let self,
                  !Task.isCancelled,
                  generation == loadGeneration,
                  currentSong?.id == song.id else { return }
            if let detailedSong {
                detailedPlaybackSongs[song.id] = detailedSong
                currentSongAudioAvailability =
                    detailedSong.audioAvailability
            }
            isResolvingCurrentSongAudioAvailability = false
            audioAvailabilityTask = nil
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension PlayerStore {
    /// Silences the output while the rig drives playback. Nothing about how
    /// playback proceeds depends on the volume.
    func debugMuteOutput() {
        engine.setVolume(0)
    }

    /// What is being streamed, without the address: a source's address
    /// carries a key that must not reach a log.
    var debugStreamSummary: String {
        guard let source = currentPlaybackSource else { return "" }
        let name = source.url.lastPathComponent
        let kind = source.url.isFileURL
            ? "file"
            : "\(name.prefix(4))….\(source.url.pathExtension)"
        return [
            source.sourceName ?? "?",
            kind,
            source.format ?? "?",
            source.bitrate.map { "\($0 / 1_000)kbps" } ?? "?",
            source.qualityVerified ? "verified" : "unverified",
        ].joined(separator: " | ")
    }

    /// Raises a playback error with nothing else happening, to observe how
    /// the interface alone reacts to one.
    func debugRaisePlaybackIssue() {
        guard let currentSong else { return }
        reportPlaybackIssue(
            PlaybackIssue(
                song: currentSong,
                error: APIError.noPlayableSource
            )
        )
    }
}
#endif
