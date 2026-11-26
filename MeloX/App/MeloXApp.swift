import Foundation
import SwiftUI

@main
struct MeloXApp: App {
    @UIApplicationDelegateAdaptor(MeloXAppDelegate.self)
    private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var settings: AppSettings
    @State private var api: NeteaseAPI
    @State private var sourceStore: LXSourceStore
    @State private var library: LibraryStore
    @State private var downloads: DownloadStore
    @State private var player: PlayerStore
    @State private var phoneWatchSync: PhoneWatchSyncService
    @State private var listenTogether: ListenTogetherStore
    @State private var lyrics: LyricsStore
    @State private var floatingLyrics: FloatingLyricsController
    @State private var lyricsNotifications:
        LyricsNotificationController
    @State private var screenAwakeCoordinator: ScreenAwakeCoordinator
    @State private var releaseNotes: AppReleaseNotesStore
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    init() {
        let settings = AppSettings()
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled {
            settings.hasCompletedOnboarding = true
            settings.setAppLanguage(.simplifiedChinese)
            settings.lastSelectedTab = .home
            if ProcessInfo.processInfo.environment["MELOX_UI_LIBRARY_HOME"] == "1" {
                settings.setPage(.libraryAlbums, placement: .home)
            }
        }
        #endif
        let releaseNotes = AppReleaseNotesStore(
            currentVersion: Bundle.main.appReleaseVersion,
            hadCompletedOnboarding: settings.hasCompletedOnboarding,
            currentReleaseNotes: AppReleaseNotesLoader.load()
        )
        let session: URLSession
        #if DEBUG && targetEnvironment(simulator)
        session = FixturePlaybackSession.isEnabled ? FixturePlaybackSession.session : .shared
        #else
        session = .shared
        #endif
        let sourceStore = LXSourceStore(session: session)
        let resolver = LXPlaybackResolver(store: sourceStore, session: session)
        let api = NeteaseAPI(
            settings: settings,
            session: session,
            resolver: resolver
        )
        let library = LibraryStore(api: api, settings: settings)
        let downloads = DownloadStore(api: api, settings: settings)
        let lyricsNotifications = LyricsNotificationController(
            preferences: settings.lyricsNotifications
        )
        let player = PlayerStore(
            api: api,
            settings: settings,
            downloads: downloads,
            lyricsNotificationController: lyricsNotifications,
            onPlaybackRecorded: { song in
                library.recordRecentlyPlayed(song)
            }
        )
        let listenTogether = ListenTogetherStore(
            api: api,
            player: player
        )
        let phoneWatchSync = PhoneWatchSyncService(
            settings: settings
        )
        let lyricService = LyricsService(api: api, settings: settings)
        let lyrics = LyricsStore(service: lyricService)
        let floatingLyrics = FloatingLyricsController(
            player: player,
            settings: settings,
            lyricsStore: lyrics
        )
        #if DEBUG && targetEnvironment(simulator)
        MeloXDebugAutomation.start(
            player: player,
            api: api,
            settings: settings,
            downloads: downloads,
            sources: sourceStore
        )
        #endif
        _settings = State(initialValue: settings)
        _api = State(initialValue: api)
        _sourceStore = State(initialValue: sourceStore)
        _library = State(initialValue: library)
        _downloads = State(initialValue: downloads)
        _player = State(initialValue: player)
        _phoneWatchSync = State(initialValue: phoneWatchSync)
        _listenTogether = State(initialValue: listenTogether)
        _lyrics = State(initialValue: lyrics)
        _floatingLyrics = State(initialValue: floatingLyrics)
        _lyricsNotifications = State(
            initialValue: lyricsNotifications
        )
        _screenAwakeCoordinator = State(initialValue: ScreenAwakeCoordinator())
        _releaseNotes = State(initialValue: releaseNotes)
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(settings)
                .environment(api)
                .environment(sourceStore)
                .environment(library)
                .environment(downloads)
                .environment(player)
                .environment(listenTogether)
                .environment(lyrics)
                .environment(floatingLyrics)
                .environment(lyricsNotifications)
                .environment(screenAwakeCoordinator)
                .environment(releaseNotes)
                .environment(\.effectiveLyricsRefreshRate, effectiveLyricsRefreshRate)
                .environment(\.locale, settings.appLanguage.locale)
                .tint(.red)
                .preferredColorScheme(
                    settings.appearance.preferredColorScheme
                )
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .NSProcessInfoPowerStateDidChange
                    )
                ) { _ in
                    isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if FixturePlaybackSession.isEnabled { return }
                    #endif
                    phoneWatchSync.start()
                    await lyricsNotifications
                        .refreshAuthorizationStatus()
                }
                .onChange(of: scenePhase) {
                    guard scenePhase == .active else { return }
                    Task {
                        await lyricsNotifications
                            .refreshAuthorizationStatus()
                    }
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG && targetEnvironment(simulator)
        if FixturePlaybackSession.isEnabled {
            FixturePlaybackControls()
        } else {
            ContentView(initialTab: settings.launchTab)
        }
        #else
        ContentView(initialTab: settings.launchTab)
        #endif
    }

    private var effectiveLyricsRefreshRate: LyricsRefreshRate {
        isLowPowerModeEnabled ? .lowPowerValue : settings.lyricsRefreshRate
    }
}
