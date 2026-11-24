import SwiftUI
import UIKit
import WidgetKit

private enum ContentSheet: String, Identifiable {
    case settings

    var id: String { rawValue }
}

private struct DeepLinkRetryModifier: ViewModifier {
    let router: DeepLinkRouter
    let currentSongID: Int?
    let presentedSheet: ContentSheet?
    let releaseNotes: AppReleaseNotesStore
    let onRequest: (Int) -> Void
    let onRetry: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: router.nowPlayingRequestCount) {
                _, count in
                onRequest(count)
            }
            .onChange(of: currentSongID) { _, _ in
                onRetry()
            }
            .onChange(of: presentedSheet) { _, _ in
                onRetry()
            }
            .onChange(of: releaseNotes.releaseNotesToPresent) {
                _, _ in
                onRetry()
            }
    }
}

private struct HeartModeLaunchReadiness: Equatable {
    let hasRestoredPlayback: Bool
    let isLoggedIn: Bool
    let canStartHeartMode: Bool
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(LyricsStore.self) private var lyrics
    @Environment(FloatingLyricsController.self) private var floatingLyrics
    @Environment(NeteaseAPI.self) private var api
    @Environment(AppReleaseNotesStore.self) private var releaseNotes

    @State private var selectedTab: AppTab
    @State private var navigationPaths = Dictionary(
        uniqueKeysWithValues: AppTab.allCases.map {
            ($0, NavigationPath())
        }
    )
    @State private var presentedSheet: ContentSheet?
    @State private var playerPresentation: PlayerPresentation?
    @State private var pendingMusicRoute: MusicRoute?
    @State private var isTabViewBottomAccessorySuppressed = false
    @State private var hasRestoredPlayback = false
    @State private var pendingNowPlayingDeepLink = false
    @State private var deepLinkRouter = DeepLinkRouter.shared
    @State private var handledDeepLinkRequestCount = 0
    @State private var hasHandledHeartModeLaunch = false
    @State private var heartModeLaunchErrorMessage: String?
    @Namespace private var playerTransitionNamespace
    @Namespace private var musicNavigationNamespace

    private let playerTransitionID = "now-playing"

    init(initialTab: AppTab = .home) {
        _selectedTab = State(initialValue: initialTab)
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled,
           let pageName = ProcessInfo.processInfo.environment["MELOX_UI_PAGE"],
           let page = NowPlayingPage(rawValue: pageName) {
            _playerPresentation = State(initialValue: .nowPlaying(initialPage: page))
        }
        #endif
    }

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainExperience
            } else {
                OnboardingView()
            }
        }
        .onOpenURL(perform: handleOpenURL)
        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
            deepLinkRouter.handleLiveActivityContinuation()
        }
    }

    private var mainExperience: some View {
        playerAwareTabView
            .environment(
                \.openMusicRoute,
                OpenMusicRouteAction(action: openMusicRoute)
            )
            .environment(
                \.setTabViewBottomAccessorySuppressed,
                SetTabViewBottomAccessorySuppressedAction {
                    isTabViewBottomAccessorySuppressed = $0
                }
            )
            .fullScreenCover(
                item: $playerPresentation,
                onDismiss: finishPendingSongNavigation
            ) { destination in
                switch destination {
                case .nowPlaying(let initialPage):
                    NowPlayingView(initialPage: initialPage)
                        .environment(
                            \.openMusicRoute,
                            OpenMusicRouteAction(action: openMusicRoute)
                        )
                        .presentationBackground(.clear)
                        .presentationContentInteraction(.resizes)
                        .navigationTransition(
                            .zoom(
                                sourceID: playerTransitionID,
                                in: playerTransitionNamespace
                            )
                        )
                }
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    NavigationStack {
                        SettingsView()
                            .musicDestinations(
                                in: musicNavigationNamespace
                            )
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(32)
                }
            }
            .task {
                await player.restore()
                guard !Task.isCancelled else { return }
                hasRestoredPlayback = true
                handleNowPlayingDeepLinkRequest(
                    deepLinkRouter.nowPlayingRequestCount
                )
                presentPlayerFromDeepLinkIfPossible()
            }
            .task(
                id: HeartModeLaunchReadiness(
                    hasRestoredPlayback: hasRestoredPlayback,
                    isLoggedIn: library.isLoggedIn,
                    canStartHeartMode: library.canStartHeartMode
                )
            ) {
                await startHeartModeOnLaunchIfNeeded()
            }
            .task(id: player.currentSong?.id) {
                await synchronizeLyrics()
            }
            .onChange(of: settings.lyricsSourcePreference) { _, _ in
                Task { await synchronizeLyrics() }
            }
            .task {
                await floatingLyrics.monitor()
            }
            .task(id: api.accountScope) {
                await library.refresh()
            }
            .background(alignment: .topLeading) {
                FloatingLyricsPictureInPictureSource(
                    controller: floatingLyrics
                )
                .frame(
                    width:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.width,
                    height:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.height
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear {
                guard usesTabletNavigation,
                      settings.restoresLastSelectedTab,
                      navigationTabs.contains(settings.lastSelectedTab) else { return }
                selectedTab = settings.lastSelectedTab
            }
            .onChange(of: selectedTab) { _, tab in
                settings.lastSelectedTab = tab
            }
            .onChange(of: navigationTabs) { _, tabs in
                guard !tabs.contains(selectedTab) else { return }
                if settings.homeTabs.contains(selectedTab),
                   tabs.contains(.home) {
                    selectedTab = .home
                } else if selectedTab.libraryPage != nil,
                   tabs.contains(.library) {
                    if let page = selectedTab.libraryPage {
                        settings.lastLibraryPage = page
                    }
                    selectedTab = .library
                } else {
                    selectedTab = settings.fallbackNavigationTab
                }
            }
            .onChange(of: scenePhase) { _, phase in
                player.refreshLyricsNotification()
                guard phase == .active else { return }
                player.refreshLyricsLiveActivity()
                presentPlayerFromDeepLinkIfPossible()
            }
            .onChange(of: floatingLyrics.restorationRequestID) {
                guard floatingLyrics.restorationRequestID > 0,
                      player.currentSong != nil else {
                    floatingLyrics.completeRestoration(success: false)
                    return
                }

                presentPlayer(page: .lyrics)
                Task { @MainActor in
                    await Task.yield()
                    floatingLyrics.completeRestoration(success: true)
                }
            }
            .alert(
                "ui.error.playback.title",
                isPresented: Binding(
                    get: { player.playbackIssue != nil },
                    set: { isPresented in
                        if !isPresented {
                            player.dismissPlaybackIssue()
                        }
                    }
                )
            ) {
                if player.canPlayNext {
                    Button("ui.player.play_next") {
                        player.dismissPlaybackIssue()
                        Task { await player.next() }
                    }
                }
                Button("ui.common.ok", role: .cancel) {
                    player.dismissPlaybackIssue()
                }
            } message: {
                Text(player.playbackIssue?.message ?? L10n.string("ui.error.playback.current_unavailable"))
            }
            .alert(
                "ui.error.heart_mode_launch.title",
                isPresented: Binding(
                    get: { heartModeLaunchErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            heartModeLaunchErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    heartModeLaunchErrorMessage = nil
                }
            } message: {
                Text(heartModeLaunchErrorMessage ?? L10n.string("ui.error.try_again_later"))
            }
            .alert(
                "ui.error.download.title",
                isPresented: Binding(
                    get: {
                        AppFeatureAvailability.downloads
                            && downloads.errorMessage != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            downloads.clearError()
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    downloads.clearError()
                }
            } message: {
                Text(downloads.errorMessage ?? L10n.string("ui.error.download.operation_failed"))
            }
            .alert(
                "ui.error.floating_lyrics.title",
                isPresented: Binding(
                    get: { floatingLyrics.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            floatingLyrics.dismissError()
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    floatingLyrics.dismissError()
                }
            } message: {
                Text(
                    floatingLyrics.errorMessage
                        ?? L10n.string("ui.error.picture_in_picture.unavailable")
                )
            }
            .modifier(
                DeepLinkRetryModifier(
                    router: deepLinkRouter,
                    currentSongID: player.currentSong?.id,
                    presentedSheet: presentedSheet,
                    releaseNotes: releaseNotes,
                    onRequest: handleNowPlayingDeepLinkRequest,
                    onRetry: presentPlayerFromDeepLinkIfPossible
                )
            )
            .coordinateListenTogether()
            .appLaunchExperience()
    }

    private func synchronizeLyrics() async {
        let song = player.currentSong
        let lyricSong = song?.isPodcastProgram == true ? nil : song
        await lyrics.load(for: lyricSong)
        guard !Task.isCancelled else { return }
        player.setNowPlayingLyrics(lyrics.lyrics, for: lyricSong?.id)
    }

    private func startHeartModeOnLaunchIfNeeded() async {
        guard !hasHandledHeartModeLaunch,
              hasRestoredPlayback else {
            return
        }
        guard settings.startsHeartModeOnLaunch else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.isLoggedIn else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.canStartHeartMode,
              let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else {
            return
        }

        hasHandledHeartModeLaunch = true
        do {
            try await player.playHeartMode(
                playlistID: playlistID,
                seedSongID: seedSongID
            )
        } catch is CancellationError {
            return
        } catch {
            heartModeLaunchErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var playerAwareTabView: some View {
        if #available(iOS 26.1, *) {
            // A single branch keeps the tab view's identity: starting the
            // first song only enables the accessory instead of rebuilding
            // every tab and resetting its scroll position.
            tabs
                .tabViewBottomAccessory(
                    isEnabled: player.currentSong != nil
                        && !isTabViewBottomAccessorySuppressed
                ) {
                    miniPlayer
                }
        } else if player.currentSong != nil {
            tabs
                .tabViewBottomAccessory {
                    if !isTabViewBottomAccessorySuppressed {
                        miniPlayer
                    }
                }
        } else {
            tabs
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if usesTabletNavigation {
            TabletMiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace,
                onExpand: presentPlayer
            )
        } else {
            MiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace
            ) {
                presentPlayer()
            }
        }
    }

    private var usesTabletNavigation: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
    }

    private var sidebarHomeTabs: [AppTab] {
        settings.homeTabs.filter {
            $0 != .recommended && $0.libraryPage == nil
                && !settings.visibleTabs.contains($0)
        }
    }

    private var sidebarLibraryTabs: [AppTab] {
        let embedded = settings.embeddedLibraryPages.map { AppTab(libraryPage: $0) }
        let homeLibraryPages = settings.homeTabs.filter { $0.libraryPage != nil }
        var seen = Set(settings.visibleTabs)
        return (embedded + homeLibraryPages).filter { seen.insert($0).inserted }
    }

    private var navigationTabs: [AppTab] {
        settings.visibleTabs
            + (usesTabletNavigation ? sidebarHomeTabs + sidebarLibraryTabs : [])
    }

    private var displayedPrimaryTabs: [AppTab] {
        guard usesTabletNavigation, settings.visibleTabs.contains(.search) else { return settings.visibleTabs }
        return [.search] + settings.visibleTabs.filter { $0 != .search }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(displayedPrimaryTabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab,
                    role: tab == .search ? .search : nil
                ) {
                    tabNavigationStack(for: tab)
                }
            }

            if usesTabletNavigation {
                if !sidebarHomeTabs.isEmpty {
                    TabSection("ui.navigation.explore") {
                        ForEach(sidebarHomeTabs) { tab in
                            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                                tabNavigationStack(for: tab)
                            }
                        }
                    }
                    .tabPlacement(.sidebarOnly)
                }

                if !sidebarLibraryTabs.isEmpty {
                    TabSection("ui.navigation.library") {
                        ForEach(sidebarLibraryTabs) { tab in
                            Tab(
                                tab.libraryPage?.title ?? tab.title,
                                systemImage: tab.systemImage,
                                value: tab
                            ) {
                                tabNavigationStack(for: tab)
                            }
                        }
                    }
                    .tabPlacement(.sidebarOnly)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(usesTabletNavigation ? .sidebar : .automatic)
        .tabViewSidebarBottomBar {
            SidebarAccountButton(accessibilityLabel: accountToolbarAccessibilityLabel) {
                presentedSheet = .settings
            } label: {
                HStack(spacing: 10) {
                    accountToolbarLabel
                        .frame(width: 28, height: 28)
                    Text(library.profile?.nickname ?? L10n.string("ui.account.login_settings"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tabBarMinimizeBehavior(usesTabletNavigation ? .never : .onScrollDown)
        .environment(\.musicUsesSidebar, usesTabletNavigation)
        .environment(\.musicNavigationNamespace, musicNavigationNamespace)
    }

    private func tabNavigationStack(for tab: AppTab) -> some View {
        NavigationStack(path: navigationPathBinding(for: tab)) {
            tabRoot(for: tab)
                .toolbar {
                    primaryToolbar(for: tab)
                }
                .musicDestinations(in: musicNavigationNamespace)
        }
    }

    private func handleOpenURL(_ url: URL) {
        deepLinkRouter.handle(url)
    }

    private func handleNowPlayingDeepLinkRequest(_ count: Int) {
        guard count > handledDeepLinkRequestCount else { return }
        handledDeepLinkRequestCount = count
        pendingNowPlayingDeepLink = true
        presentPlayerFromDeepLinkIfPossible()
    }

    private func presentPlayerFromDeepLinkIfPossible() {
        guard pendingNowPlayingDeepLink, hasRestoredPlayback else { return }
        // Read the live application state instead of the scenePhase value
        // captured when the view was created; a cold launch can finish
        // restoring after the scene already became active.
        guard UIApplication.shared.applicationState == .active else { return }
        guard presentedSheet == nil,
              releaseNotes.releaseNotesToPresent == nil else {
            return
        }
        guard player.currentSong != nil else { return }
        guard playerPresentation == nil else {
            pendingNowPlayingDeepLink = false
            return
        }
        pendingNowPlayingDeepLink = false
        presentPlayer()
    }

    private func presentPlayer(page: NowPlayingPage? = nil) {
        if let page, settings.rememberNowPlayingPage {
            settings.rememberedNowPlayingPage = page.rawValue
        }
        playerPresentation = .nowPlaying(initialPage: page ?? initialNowPlayingPage)
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .recommended:
            HomeRecommendedView()
                .navigationTitle("ui.navigation.recommended")
                .navigationBarTitleDisplayMode(.large)
        case .music:
            ExploreView()
        case .explore:
            ExploreView()
        case .library:
            LibraryView()
        case .search:
            SearchView()
        case .librarySongs,
             .libraryPlaylists,
             .libraryAlbums,
             .libraryArtists,
             .libraryDownloads,
             .libraryHistory:

            if let page = tab.libraryPage {
                LibraryView(fixedPage: page)
            }
        }
    }

    @ToolbarContentBuilder
    private func primaryToolbar(
        for tab: AppTab
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !usesTabletNavigation {
                Button {
                    presentedSheet = .settings
                } label: {
                    accountToolbarLabel
                }
                .accessibilityLabel(accountToolbarAccessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private var accountToolbarLabel: some View {
        if let profile = library.profile {
            AsyncImage(url: profile.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(.quaternary, in: .circle)
            .clipShape(.circle)
        } else {
            MusicToolbarSymbol(
                systemName: library.isLoggedIn
                    ? "person.crop.circle.fill"
                    : "person.crop.circle"
            )
        }
    }

    private var accountToolbarAccessibilityLabel: String {
        if let profile = library.profile {
            return L10n.format("ui.account.settings_for_user", profile.nickname)
        }
        return library.isLoggedIn
            ? L10n.string("ui.account.settings")
            : L10n.string("ui.account.login_settings")
    }

    private func navigationPathBinding(
        for tab: AppTab
    ) -> Binding<NavigationPath> {
        Binding(
            get: {
                navigationPaths[tab] ?? NavigationPath()
            },
            set: {
                navigationPaths[tab] = $0
            }
        )
    }

    private var initialNowPlayingPage: NowPlayingPage {
        guard settings.rememberNowPlayingPage else { return .artwork }
        return NowPlayingPage(rawValue: settings.rememberedNowPlayingPage) ?? .artwork
    }

    private func openMusicRoute(_ route: MusicRoute) {
        guard playerPresentation == nil else {
            pendingMusicRoute = route
            playerPresentation = nil
            return
        }
        navigate(to: route)
    }

    private func finishPendingSongNavigation() {
        guard let route = pendingMusicRoute else { return }
        pendingMusicRoute = nil
        navigate(to: route)
    }

    private func navigate(to route: MusicRoute) {
        var path = navigationPaths[selectedTab] ?? NavigationPath()
        path.append(route)
        navigationPaths[selectedTab] = path
    }
}
