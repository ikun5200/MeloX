import SwiftUI
import UIKit

struct NowPlayingView: View {
    private static let portraitHorizontalPadding: CGFloat = 32

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled)
    private var accessibilityVoiceOverEnabled
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsStore.self) private var lyricsStore

    @State private var pageTransition: NowPlayingTransitionCoordinator
    @State private var showsLyricsControls = true
    @State private var appleMusicControlsActivityGeneration = 0
    @State private var highlightedLyricID: LyricLine.ID?
    @State private var showsTextPVLandscapeSuggestion = false
    @State private var isQueueSongHeaderHidden = false
    @State private var queueHeaderScroll = NowPlayingQueueHeaderScroll()
    @State private var artworkPageFrame = CGRect.zero
    @State private var preparedLyricsSongID: Song.ID?
    @State private var hasDisplayDivision = false
    @State private var viewportSize = CGSize.zero
    @State private var showsFullScreenLyrics = false
    @State private var controlActivityGeneration = 0
    @State private var hidesControlsForInactivity = false
    @State private var isAdjustingControls = false
    @Namespace private var pageArtworkNamespace

    private var page: NowPlayingPage {
        pageTransition.page
    }

    init(initialPage: NowPlayingPage = .artwork) {
        _pageTransition = State(
            initialValue: NowPlayingTransitionCoordinator(
                initialPage: initialPage
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if usesMonochromeLyricsBackground {
                    Color.black
                        .ignoresSafeArea()
                } else {
                    NowPlayingBackground(
                        artworkURL:
                            player.currentSong?
                                .album?
                                .artworkURL,
                        beatTimeline:
                            player.currentBeatTimeline,
                        isBehindLyrics:
                            page == .lyrics,
                        isTransitioning:
                            pageTransition.transition != nil
                    )
                }

                if let song = player.currentSong {
                    if showsFullScreenLyrics, page == .lyrics {
                        fullScreenLyrics(for: song)
                    } else if usesExpandedLayout {
                        NowPlayingTabletView(
                            page: pageSelection,
                            pageTransition: pageTransition,
                            song: song,
                            hasDisplayDivision: hasDisplayDivision,
                            lyrics: lyrics,
                            lyricError: lyricError,
                            highlightedLyricID: highlightedLyricID,
                            artworkNamespace: pageArtworkNamespace,
                            onDismiss: { dismiss() },
                            onExpandLyrics: {
                                showsLyricsControls = true
                                showsFullScreenLyrics = true
                            },
                            onLyricsContentPrepared: {
                                markLyricsContentPrepared(for: song.id)
                            }
                        )
                    } else if usesFullScreenTextPV {
                        TextPVFullScreenPlayerView(
                            page: pageSelection,
                            showsControls: $showsLyricsControls,
                            song: song,
                            lyrics: lyrics,
                            errorMessage: lyricError,
                            highlightedLyricID: highlightedLyricID,
                            onDismiss: { dismiss() },
                            onToggleInterface:
                                toggleLyricsControls
                        )
                        .transition(.opacity)
                    } else if proxy.size.width > proxy.size.height {
                        NowPlayingLandscapeView(
                            page: pageSelection,
                            pageTransition: pageTransition,
                            showsLyricsControls: showsLyricsControls,
                            song: song,
                            lyrics: lyrics,
                            lyricError: lyricError,
                            highlightedLyricID: highlightedLyricID,
                            artworkNamespace: pageArtworkNamespace,
                            onDismiss: { dismiss() },
                            onInterfaceInteraction:
                                handleLyricsInterfaceInteraction,
                            onInterfaceVisibilityChange:
                                setAppleMusicLyricsControlsVisible,
                            onLyricsContentPrepared: {
                                markLyricsContentPrepared(
                                    for: song.id
                                )
                            }
                        )
                    } else {
                        portraitContent(for: song)
                    }
                } else {
                    ContentUnavailableView("ui.player.no_current_song", systemImage: "music.note")
                        .foregroundStyle(.white)
                }

                if usesFullScreenTextPV,
                   showsTextPVLandscapeSuggestion,
                   proxy.size.width <= proxy.size.height {
                    Label("ui.text_pv.landscape_recommended", systemImage: "rectangle.landscape.rotate")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.regularMaterial, in: .capsule)
                        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .safeAreaPadding(.top, 58)
                        .accessibilityLabel("ui.text_pv.landscape_recommended")
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewportSize = size
        }
        .onGeometryChange(for: Bool.self) { proxy in
            if #available(iOS 27.1, *) {
                // Keep the inner-display layout stable while the fold flattens.
                !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
            } else {
                false
            }
        } action: { hasDivision in
            hasDisplayDivision = hasDivision
        }
        .background {
            NowPlayingLyricSynchronizer(
                lyrics: lyrics,
                highlightedLyricID: $highlightedLyricID
            )
        }
        .keepsScreenAwake(keepsPlayerScreenAwake)
        .preferredColorScheme(.dark)
        .task(id: beatAnalysisTaskID) {
            await loadBeatTimeline()
        }
        .task(id: usesFullScreenTextPV) {
            guard usesFullScreenTextPV else {
                showsTextPVLandscapeSuggestion = false
                return
            }

            withAnimation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25)) {
                showsTextPVLandscapeSuggestion = true
            }
            do {
                try await Task.sleep(for: .seconds(3.2))
            } catch {
                return
            }
            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                showsTextPVLandscapeSuggestion = false
            }
        }
        .task(id: appleMusicControlsActivityGeneration) {
            guard usesAutoHidingAppleMusicInterface,
                  showsLyricsControls,
                  !accessibilityVoiceOverEnabled else {
                return
            }

            do {
                try await Task.sleep(
                    for: .seconds(
                        settings
                            .appleMusicLyricsInterfaceAutoHideDelay
                    )
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  usesAutoHidingAppleMusicInterface else {
                return
            }

            withAnimation(
                NowPlayingInterfaceTransition.interfaceAnimation(
                    isVisible: false,
                    reducesMotion: accessibilityReduceMotion
                )
            ) {
                showsLyricsControls = false
            }
        }
        .task(id: controlActivityGeneration) {
            await hideControlsAfterInactivity()
        }
        .task(id: transitionSettlementTaskID) {
            await settlePageTransition()
        }        .task(id: lyricsEntranceTaskID) {
            await presentLyricsEntrance()
        }
        .onChange(of: page) { _, newPage in
            showsFullScreenLyrics = false
            revealControls()
            if newPage == .lyrics,
               settings.lyricsStyle == .appleMusic {
                registerAppleMusicControlsActivity()
            } else {
                cancelAppleMusicControlsAutoHide()
                showsLyricsControls = true
            }

            guard settings.rememberNowPlayingPage else { return }
            settings.rememberedNowPlayingPage = newPage.rawValue
        }
        .onChange(of: accessibilityVoiceOverEnabled) {
            _, voiceOverEnabled in
            guard usesAutoHidingAppleMusicInterface else { return }

            if voiceOverEnabled {
                cancelAppleMusicControlsAutoHide()
                showsLyricsControls = true
            } else {
                registerAppleMusicControlsActivity()
            }
        }
        .onChange(of: settings.lyricsStyle) { _, newStyle in
            cancelAppleMusicControlsAutoHide()
            showsLyricsControls = true

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageTransition.synchronizeLyricsVisibility(
                    isVisible:
                        page == .lyrics
                        && newStyle == .appleMusic
                )
            }

            if page == .lyrics, newStyle == .appleMusic {
                registerAppleMusicControlsActivity()
            }
        }
        .onChange(of: usesExpandedLayout) {
            cancelAppleMusicControlsAutoHide()
            showsLyricsControls = true
            registerAppleMusicControlsActivity()
        }
        .onChange(
            of: settings.appleMusicLyricsInterfaceAutoHideDelay
        ) {
            registerAppleMusicControlsActivity()
        }
        .onAppear {
            resetPodcastPageIfNeeded()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            // A paused player needs its transport row visible.
            if !isPlaying {
                revealControls()
            }
        }
        .onChange(of: player.currentSong?.id) {
            resetPodcastPageIfNeeded()
        }
    }

    private var beatAnalysisTaskID:
        NowPlayingBeatAnalysisTaskID {
        NowPlayingBeatAnalysisTaskID(
            songID: player.currentSong?.id,
            isPlaybackReady: !player.isLoading,
            isEnabled:
                settings.playerBackgroundStyle
                    == .flowingLight
                    && settings
                        .playerBackgroundBeatEffectsEnabled
                    && player.currentSong?.isPodcastProgram != true
        )
    }

    private func loadBeatTimeline() async {
        let taskID = beatAnalysisTaskID
        guard taskID.isEnabled else {
            player.clearCurrentSongBeatAnalysis()
            return
        }
        guard
              taskID.isPlaybackReady,
              taskID.songID != nil else {
            return
        }

        await player.analyzeCurrentSongBeats()
    }

    private func resetPodcastPageIfNeeded() {
        guard player.currentSong?.isPodcastProgram == true,
              page == .lyrics else {
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageTransition.reset(to: .artwork)
        }
    }

    private func portraitContent(for song: Song) -> some View {
        VStack(spacing: 0) {
            dismissalHandle

            pageContent(for: song)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    portraitPlayerControlsLayer(for: song)
                }
        }
        .padding(.horizontal, Self.portraitHorizontalPadding)
        .safeAreaPadding(.bottom, 3)
    }

    @ViewBuilder
    private func fullScreenLyrics(for song: Song) -> some View {
        if settings.lyricsStyle == .textPV {
            TextPVFullScreenPlayerView(
                page: pageSelection,
                showsControls: $showsLyricsControls,
                song: song,
                lyrics: lyrics,
                errorMessage: lyricError,
                highlightedLyricID: highlightedLyricID,
                onDismiss: { showsFullScreenLyrics = false },
                onToggleInterface: toggleLyricsControls
            )
        } else {
            SkylineLyricsView(
                artworkURL: song.album?.artworkURL,
                lyrics: lyrics,
                errorMessage: lyricError,
                highlightedLyricID: highlightedLyricID,
                onExit: { showsFullScreenLyrics = false }
            )
        }
    }

    private func portraitPlayerControlsLayer(
        for song: Song
    ) -> some View {
        ZStack(alignment: .bottom) {
            portraitPlayerControls(for: song)
                .allowsHitTesting(!hidesPlayerInterface)
                .accessibilityHidden(hidesPlayerInterface)

            if hidesLyricsControls,
               settings.lyricsStyle != .appleMusic {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(
                        height: NowPlayingBottomControls.overlayHeight
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        handleLyricsInterfaceInteraction()
                    }
                    .accessibilityHidden(true)
            } else if hidesControlsForInactivity {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(
                        height: NowPlayingBottomControls.overlayHeight
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        revealControls(restartsCountdown: true)
                    }
                    .accessibilityLabel("ui.player.show_controls")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(height: NowPlayingBottomControls.overlayHeight)
    }

    private func portraitPlayerControls(for song: Song) -> some View {
        NowPlayingBottomControls(
            song: song,
            page: pageSelection,
            showsLyricsUtilities:
                usesExpandedAppleMusicLyricsLayout,
            hasLyricsTranslations: hasLyricsTranslations,
            hasLyricsRomanizations: hasLyricsRomanizations,
            isInterfaceHidden: hidesPlayerInterface,
            onControlAdjustmentChanged: handleControlAdjustment
        )
    }

    private var pageSelection: Binding<NowPlayingPage> {
        Binding(
            get: { page },
            set: { newPage in
                pageTransition.select(
                    newPage,
                    usesAppleMusicLyrics:
                        settings.lyricsStyle == .appleMusic,
                    isQueueSongHeaderHidden:
                        isQueueSongHeaderHidden,
                    motion: NowPlayingPageTransition.motion
                )
            }
        )
    }

    private var hidesLyricsControls: Bool {
        page == .lyrics && !showsLyricsControls
    }

    /// The bottom panel is either hidden with the lyrics interface or because
    /// the listener stopped adjusting it a few seconds ago.
    private var hidesPlayerInterface: Bool {
        hidesLyricsControls || hidesControlsForInactivity
    }

    private var usesAutoHidingAppleMusicInterface: Bool {
        !usesExpandedLayout
            && page == .lyrics
            && settings.lyricsStyle == .appleMusic
    }

    private var lyrics: [LyricLine] {
        lyricsStore.lyrics
    }

    private var lyricError: String? {
        lyricsStore.errorMessage
    }

    private var hasLyricsTranslations: Bool {
        lyrics.contains { $0.hasTranslation }
    }

    private var hasLyricsRomanizations: Bool {
        lyrics.contains { $0.hasRomanization }
    }

    private var keepsPlayerScreenAwake: Bool {
        switch settings.playerScreenAwakeMode {
        case .disabled:
            false
        case .player:
            true
        case .lyrics:
            page == .lyrics
        case .hiddenLyricsInterface:
            hidesLyricsControls
        }
    }

    private var usesExpandedAppleMusicLyricsLayout: Bool {
        page == .lyrics && settings.lyricsStyle == .appleMusic
    }

    private var usesFullScreenTextPV: Bool {
        (!usesExpandedLayout || showsFullScreenLyrics)
            && page == .lyrics && settings.lyricsStyle == .textPV
    }

    private var usesExpandedLayout: Bool {
        hasDisplayDivision
            || (viewportSize.width >= 700
                && viewportSize.height >= 500
                && (UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular))
    }

    private var usesMonochromeLyricsBackground: Bool {
        page == .lyrics && settings.lyricsStyle.usesMonochromePlayerBackground
    }

    private var dismissalHandle: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.52))
                .frame(width: 60, height: 5)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture {
            dismiss()
        }
        .accessibilityElement()
        .accessibilityLabel("ui.player.collapse")
        .accessibilityHint("ui.player.collapse_hint")
        .accessibilityAction {
            dismiss()
        }
    }

    private func pageContent(for song: Song) -> some View {
        ZStack(alignment: .top) {
            transientArtworkPageContent(for: song)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .clipped()

            residentQueuePage(for: song)

            if settings.lyricsStyle == .appleMusic {
                residentAppleMusicLyricsPage(for: song)
            } else if page == .lyrics {
                portraitLyricsPage(for: song)
                    .clipped()
                    .transition(
                        pageContentTransition(for: .lyrics)
                    )
            }

            if page != .artwork {
                NowPlayingQueueHeaderOffsetReader(
                    scroll: queueHeaderScroll,
                    isActive: page == .queue
                ) { headerOffset in
                    sharedPortraitSongHeader(for: song)
                        .offset(y: headerOffset)
                }
                .clipped()
                .transition(
                    NowPlayingPageTransition.songHeader(
                        reducesMotion: accessibilityReduceMotion
                    )
                )
            }

        }
        .background {
            if keepsStableArtworkFrameMeasurement {
                artworkFrameMeasurement(for: song)
            }
        }
        .overlay {
            GeometryReader { proxy in
                if artworkPageFrame.width > 0 {
                    let artworkReturnsToPlayer = page == .lyrics
                    let artworkScale = artworkOverlayScale

                    NowPlayingQueueHeaderOffsetReader(
                        scroll: queueHeaderScroll,
                        isActive: page == .queue
                    ) { headerOffset in
                        portraitArtworkOverlay(
                            for: song,
                            scale: artworkScale,
                            offset: artworkOverlayOffset(
                                headerOffset: headerOffset
                            ),
                            size: proxy.size
                        )
                    }

                    if artworkReturnsToPlayer {
                        Color.clear
                            .frame(
                                width: NowPlayingSongHeader.referenceHeight,
                                height: NowPlayingSongHeader.referenceHeight
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                pageSelection.wrappedValue = .artwork
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(
                                L10n.string("ui.player.show_artwork_page")
                            )
                            .position(
                                x:
                                    NowPlayingSongHeader.referenceHeight / 2
                                    + Self.portraitHorizontalPadding,
                                y:
                                    NowPlayingSongHeader.referenceHeight / 2
                            )
                    }
                }
            }
            // Keep page-transition clipping vertically while allowing the
            // expanded artwork to use the portrait layout's side margins.
            .clipped()
            .padding(
                .horizontal,
                -Self.portraitHorizontalPadding
            )
        }
        .coordinateSpace(
            name: NowPlayingPortraitCoordinateSpace.name
        )
    }

    @ViewBuilder
    private func transientArtworkPageContent(
        for song: Song
    ) -> some View {
        if page == .artwork {
            NowPlayingArtworkPage(
                song: song,
                artworkNamespace: pageArtworkNamespace,
                usesArtworkTransition: false,
                showsArtwork: false,
                onArtworkFrameChange:
                    recordPresentedArtworkPageFrame
            )
            .transition(
                pageContentTransition(for: .artwork)
            )
        }
    }

    private func artworkFrameMeasurement(
        for song: Song
    ) -> some View {
        NowPlayingArtworkPage(
            song: song,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsArtwork: false,
            onArtworkFrameChange: recordArtworkPageFrame
        )
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var keepsStableArtworkFrameMeasurement: Bool {
        page != .artwork || pageTransition.transition != nil
    }

    private func recordPresentedArtworkPageFrame(
        _ frame: CGRect
    ) {
        // The artwork page enters from below. Its geometry includes that
        // temporary transition offset, so keep using the resident
        // measurement until the page transition has settled.
        guard pageTransition.transition == nil else { return }
        recordArtworkPageFrame(frame)
    }

    private func recordArtworkPageFrame(_ frame: CGRect) {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return
        }
        let tolerance: CGFloat = 0.5
        guard abs(artworkPageFrame.minX - frame.minX) > tolerance
                || abs(artworkPageFrame.minY - frame.minY) > tolerance
                || abs(artworkPageFrame.width - frame.width) > tolerance
                || abs(artworkPageFrame.height - frame.height) > tolerance else {
            return
        }
        artworkPageFrame = frame
    }

    private func residentQueuePage(
        for song: Song
    ) -> some View {
        let visualState = residentQueueVisualState

        return NowPlayingQueuePage(
            song: song,
            presentation: .portrait,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsSongHeader: false,
            onSongHeaderHiddenChange: {
                isQueueSongHeaderHidden = $0
            },
            onSongHeaderOffsetChange: {
                queueHeaderScroll.offset = $0
            }
        )
        .clipped()
        .nowPlayingQueuePagePresentation(
            visualState: visualState,
            opacityTransition: pageTransition.queueOpacityTransition,
            spatialTransition: pageTransition.queueSpatialTransition,
            opacitySpec:
                pageTransition.queueOpacityTransition.targetProgress >= 1
                    ? NowPlayingPageTransition.motion
                        .queueOpacityPresentation
                    : NowPlayingPageTransition.motion
                        .queueOpacityDismissal,
            presentationScale:
                NowPlayingPageTransition.motion.queuePresentationScale,
            reducesMotion: accessibilityReduceMotion
        )
        .allowsHitTesting(page == .queue)
        .accessibilityHidden(page != .queue)
    }

    private func portraitLyricsPage(
        for song: Song,
        onInitialFocusPrepared: (() -> Void)? = nil
    ) -> some View {
        NowPlayingLyricsPage(
            song: song,
            lyrics: lyrics,
            errorMessage: lyricError,
            highlightedLyricID: highlightedLyricID,
            isActive: page == .lyrics,
            isTransitioning: pageTransition.transition != nil,
            isInterfaceHidden: hidesLyricsControls,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition:
                !pageTransition.entersFromHiddenQueue,
            showsSongHeader: false,
            onInterfaceInteraction:
                handleLyricsInterfaceInteraction,
            onInterfaceVisibilityChange:
                setAppleMusicLyricsControlsVisible,
            onInitialFocusPrepared: onInitialFocusPrepared
        )
        .accessibilityAction(
            named: lyricsInterfaceAccessibilityActionName
        ) {
            handleLyricsInterfaceInteraction()
        }
    }

    private func residentAppleMusicLyricsPage(
        for song: Song
    ) -> some View {
        let visualState = residentLyricsVisualState

        return portraitLyricsPage(
            for: song,
            onInitialFocusPrepared: {
                markLyricsContentPrepared(for: song.id)
            }
        )
        .id(song.id)
        .nowPlayingLyricsPagePresentation(
            visualState: visualState,
            opacityTransition:
                pageTransition.lyricsOpacityTransition,
            spatialTransition:
                pageTransition.lyricsSpatialTransition,
            opacitySpec:
                pageTransition.lyricsOpacityTransition
                    .targetProgress >= 1
                    ? NowPlayingPageTransition.motion
                        .lyricsOpacityPresentation
                    : NowPlayingPageTransition.motion
                        .lyricsOpacityDismissal,
            presentationScale:
                NowPlayingPageTransition.motion
                    .lyricsPresentationScale,
            reducesMotion: accessibilityReduceMotion
        )
        .allowsHitTesting(page == .lyrics)
        .accessibilityHidden(page != .lyrics)
    }

    private var residentLyricsVisualState: NowPlayingPageVisualState {
        NowPlayingPageTransition.motion.residentLyricsState(
            selectedPage: page,
            transition: pageTransition.transition,
            isEntrancePresented:
                pageTransition.isLyricsEntrancePresented
        )
    }

    private var residentQueueVisualState: NowPlayingPageVisualState {
        NowPlayingPageTransition.motion.residentQueueState(
            selectedPage: page,
            transition: pageTransition.transition
        )
    }

    private func sharedPortraitSongHeader(
        for song: Song
    ) -> some View {
        NowPlayingSongHeader(
            song: song,
            artworkNamespace: pageArtworkNamespace,
            usesReferenceLayout: true,
            usesArtworkTransition: false,
            showsArtwork: false
        )
    }

    private var artworkReturnScale: CGFloat {
        guard artworkPageFrame.width > 0 else { return 1 }
        return NowPlayingSongHeader.referenceHeight
            / artworkPageFrame.width
    }

    private func artworkReturnOffset(
        headerOffset: CGFloat
    ) -> CGSize {
        guard artworkPageFrame.width > 0 else { return .zero }
        let smallCenter = CGPoint(
            x: NowPlayingSongHeader.referenceHeight / 2,
            y: headerOffset
                + NowPlayingSongHeader.referenceHeight / 2
        )
        return CGSize(
            width: smallCenter.x - artworkPageFrame.midX,
            height: smallCenter.y - artworkPageFrame.midY
        )
    }

    private var artworkOverlayScale: CGFloat {
        if page == .artwork {
            return isPortraitArtworkExpanded
                ? 1
                : NowPlayingArtworkPage.pausedArtworkScale
        }
        return artworkReturnScale
    }

    private func artworkOverlayOffset(
        headerOffset: CGFloat
    ) -> CGSize {
        page == .artwork
            ? .zero
            : artworkReturnOffset(headerOffset: headerOffset)
    }

    /// The moving artwork: a SwiftUI shadow and bounce under the Core
    /// Animation image layer. Built from the queue header reader so a queue
    /// scroll re-evaluates only this, not the whole player.
    private func portraitArtworkOverlay(
        for song: Song,
        scale artworkScale: CGFloat,
        offset artworkOffset: CGSize,
        size: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            NowPlayingPortraitArtwork(
                song: song,
                isArtworkPage: page == .artwork,
                showsImage: false
            )
            .frame(
                width: artworkPageFrame.width,
                height: artworkPageFrame.height
            )
            .scaleEffect(artworkScale)
            .offset(artworkOffset)
            .position(
                x:
                    artworkPageFrame.midX
                    + Self.portraitHorizontalPadding,
                y: artworkPageFrame.midY
            )
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : NowPlayingPageTransition
                        .motion
                        .artworkResize
                        .animation,
                value: isPortraitArtworkExpanded
            )
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : .spring(
                        response: 0.5,
                        dampingFraction: 0.88,
                        blendDuration: 0.08
                    ),
                value: page
            )

            NowPlayingArtworkLayerView(
                url: song.album?.artworkURL,
                imageSize: artworkPageFrame.size,
                targetFrame: artworkOverlayFrame(
                    scale: artworkScale,
                    offset: artworkOffset
                ),
                page: page,
                isExpanded: isPortraitArtworkExpanded,
                isPlaying: player.isPlaying,
                reducesMotion: accessibilityReduceMotion
            )
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The artwork's visible rectangle in the overlay's coordinate space,
    /// which extends past the page content by the portrait side margins.
    private func artworkOverlayFrame(
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        let size = CGSize(
            width: artworkPageFrame.width * scale,
            height: artworkPageFrame.height * scale
        )
        return CGRect(
            x: artworkPageFrame.midX
                + Self.portraitHorizontalPadding
                + offset.width
                - size.width / 2,
            y: artworkPageFrame.midY
                + offset.height
                - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var isPortraitArtworkExpanded: Bool {
        player.isPlaying || !settings.shrinksPausedArtwork
    }

    private func pageContentTransition(
        for destination: NowPlayingPage
    ) -> AnyTransition {
        if NowPlayingPageTransition.isDirectLyricsQueueTransition(
            from: pageTransition.sourcePage,
            to: pageTransition.destinationPage
        ) {
            return NowPlayingPageTransition.directAlternateContent(
                reducesMotion: accessibilityReduceMotion
            )
        }

        return NowPlayingPageTransition.content(
            for: destination,
            entersFromHiddenQueue:
                pageTransition.entersFromHiddenQueue,
            reducesMotion: accessibilityReduceMotion
        )
    }

    private var transitionSettlementTaskID:
        NowPlayingTransitionSettlementTaskID {
        NowPlayingTransitionSettlementTaskID(
            requestID: pageTransition.transition?.id,
            isLyricsEntrancePresented:
                pageTransition.isLyricsEntrancePresented
        )
    }

    private var lyricsEntranceTaskID:
        NowPlayingLyricsEntranceTaskID {
        NowPlayingLyricsEntranceTaskID(
            requestID: pageTransition.pendingLyricsEntrance?
                .requestID,
            songID: player.currentSong?.id,
            preparedSongID: preparedLyricsSongID,
            isContentPrepared: isLyricsContentPrepared
        )
    }

    private func settlePageTransition() async {
        guard let transition = pageTransition.transition,
              pageTransition.isLyricsEntrancePresented else {
            return
        }

        let now = ContinuousClock.now
        let settlementDuration = accessibilityReduceMotion
            ? 0
            : max(
                NowPlayingPageTransition.motion.settlementDuration(
                    for: transition
                ),
                pageTransition.activeMotionRemainingDuration(at: now)
            )
        if settlementDuration > 0 {
            do {
                try await Task.sleep(
                    for: .seconds(settlementDuration)
                )
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              page == transition.destination,
              pageTransition.transition?.id == transition.id else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageTransition.settleTransition(
                requestID: transition.id
            )
        }
    }

    private func presentLyricsEntrance() async {
        guard let pendingEntrance =
            pageTransition.pendingLyricsEntrance else {
            return
        }
        let requestID = pendingEntrance.requestID

        await Task.yield()
        guard !Task.isCancelled,
              pageTransition.pendingLyricsEntrance?.requestID
                == requestID else {
            return
        }

        if accessibilityReduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageTransition.presentLyricsEntrance(
                    requestID: requestID,
                    motion: NowPlayingPageTransition.motion
                )
            }
            return
        }

        guard page == .lyrics,
              pageTransition.usesStagedLyricsEntrance else {
            return
        }

        let presentationDeadline = isLyricsContentPrepared
            ? pendingEntrance.notBefore
            : pendingEntrance.fallbackAt
        let remainingDelay = ContinuousClock.now.duration(
            to: presentationDeadline
        )
        if remainingDelay > .zero {
            do {
                try await Task.sleep(for: remainingDelay)
            } catch {
                return
            }
        }

        guard !Task.isCancelled,
              page == .lyrics,
              pageTransition.pendingLyricsEntrance?.requestID
                == requestID else {
            return
        }

        pageTransition.presentLyricsEntrance(
            requestID: requestID,
            motion: NowPlayingPageTransition.motion
        )
    }

    private var isLyricsContentPrepared: Bool {
        lyrics.isEmpty
            || preparedLyricsSongID == player.currentSong?.id
    }

    private func markLyricsContentPrepared(for songID: Song.ID) {
        guard player.currentSong?.id == songID else { return }
        preparedLyricsSongID = songID
    }

    private var lyricsInterfaceAccessibilityActionName: String {
        if settings.lyricsStyle == .appleMusic {
            return L10n.string("ui.player.show_controls")
        }
        return showsLyricsControls
            ? L10n.string("ui.player.hide_controls")
            : L10n.string("ui.player.show_controls")
    }

    private func handleLyricsInterfaceInteraction() {
        revealControls()
        if settings.lyricsStyle == .appleMusic {
            registerAppleMusicControlsActivity()
        } else {
            toggleLyricsControls()
        }
    }

    private func registerAppleMusicControlsActivity() {
        guard usesAutoHidingAppleMusicInterface else { return }

        appleMusicControlsActivityGeneration &+= 1
        guard !showsLyricsControls else { return }

        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: true,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            showsLyricsControls = true
        }
    }

    private func setAppleMusicLyricsControlsVisible(_ isVisible: Bool) {
        guard usesAutoHidingAppleMusicInterface else { return }
        if isVisible {
            revealControls()
            registerAppleMusicControlsActivity()
            return
        }

        guard showsLyricsControls,
              !accessibilityVoiceOverEnabled else {
            return
        }
        cancelAppleMusicControlsAutoHide()
        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: false,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            showsLyricsControls = false
        }
    }

    private func toggleLyricsControls() {
        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: !showsLyricsControls,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            showsLyricsControls.toggle()
        }
    }

    private func cancelAppleMusicControlsAutoHide() {
        appleMusicControlsActivityGeneration &+= 1
    }

    /// Called while a scrubber or the volume slider is being dragged. The
    /// panel stays up during the drag; the countdown starts on release.
    private func handleControlAdjustment(isAdjusting: Bool) {
        guard isAdjusting != isAdjustingControls else { return }

        isAdjustingControls = isAdjusting
        revealControls(restartsCountdown: true)
    }

    /// Fades the bottom panel back in. Only a fresh adjustment or a touch on
    /// the panel restarts the countdown; arriving on a page does not.
    private func revealControls(restartsCountdown: Bool = false) {
        if hidesControlsForInactivity {
            withAnimation(
                NowPlayingInterfaceTransition.interfaceAnimation(
                    isVisible: true,
                    reducesMotion: accessibilityReduceMotion
                )
            ) {
                hidesControlsForInactivity = false
            }
        }
        if restartsCountdown {
            controlActivityGeneration &+= 1
        }
    }

    /// Hides the bottom panel a few seconds after the last adjustment, so a
    /// scrubbed song or a nudged volume does not leave the panel covering the
    /// artwork. Any touch on the panel brings it back. Opening the player is
    /// not an adjustment: with no interaction yet there is no countdown.
    private func hideControlsAfterInactivity() async {
        guard controlActivityGeneration > 0,
              !isAdjustingControls,
              player.isPlaying,
              !accessibilityVoiceOverEnabled,
              !hidesLyricsControls,
              !hidesControlsForInactivity else {
            return
        }

        do {
            try await Task.sleep(
                for: .seconds(
                    settings.appleMusicLyricsInterfaceAutoHideDelay
                )
            )
        } catch {
            return
        }
        guard !Task.isCancelled,
              !isAdjustingControls,
              player.isPlaying else {
            return
        }

        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: false,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            hidesControlsForInactivity = true
        }
    }
}

private struct NowPlayingBeatAnalysisTaskID: Equatable {
    let songID: Int?
    let isPlaybackReady: Bool
    let isEnabled: Bool
}

private struct NowPlayingTransitionSettlementTaskID: Equatable {
    let requestID: UUID?
    let isLyricsEntrancePresented: Bool
}

private struct NowPlayingLyricsEntranceTaskID: Equatable {
    let requestID: UUID?
    let songID: Song.ID?
    let preparedSongID: Song.ID?
    let isContentPrepared: Bool
}
