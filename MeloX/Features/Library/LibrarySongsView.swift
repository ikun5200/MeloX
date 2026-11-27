import SwiftUI

struct LibrarySongsView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(NeteaseAPI.self) private var api
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.setTabViewBottomAccessorySuppressed)
    private var setTabViewBottomAccessorySuppressed

    @State private var searchReloadToken = 0
    @State private var searchPreparationID: UUID?
    @State private var isStartingHeartMode = false
    @State private var heartModeErrorMessage: String?
    @State private var isPreparingPlayback = false
    @State private var playbackErrorMessage: String?
    @State private var trackLocator = MusicCollectionTrackLocator()
    @State private var songToLocate: Int?
    @State private var locateErrorMessage: String?
    @State private var selection = MusicCollectionSelection()
    @State private var draftOrder: FavoriteSongOrder?
    @State private var reorderAccountScope: String?
    @State private var isPreparingOrder = false
    @State private var isPerformingBatch = false
    @State private var editingOperationID: UUID?
    @State private var showsRemovalConfirmation = false
    @State private var operationErrorMessage: String?
    @State private var playlistSelection: FavoritePlaylistSelection?
    @State private var downloadCoordinator = MusicCollectionDownloadCoordinator()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !displayedSongs.isEmpty, !isEditing {
                    Button(action: playDisplayedSongs) {
                        HStack {
                            Label(
                                isSearching
                                    ? L10n.string("ui.common.play_search_results")
                                    : L10n.string("ui.common.play_all"),
                                systemImage: "play.fill"
                            )
                            Spacer()
                            if isPreparingPlayback {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isPreparingPlayback)
                    if !isSearching { heartModeButton }
                }

                ForEach(displayedSongs) { song in
                    songRow(song)
                        .id(song.id)
                        .accessibilityIdentifier("favorite-song-\(song.id)")
                        .listRowBackground(
                            trackLocator.highlightedSongID == song.id
                                ? Color.accentColor.opacity(0.16) : nil
                        )
                        .moveDisabled(!isReordering || isSearching || isBusy)
                }
                .onMove { source, destination in
                    guard !isSearching, !isBusy, let draftOrder else { return }
                    self.draftOrder = draftOrder.moving(fromOffsets: source, toOffset: destination)
                }

                if !isReordering { paginationFooter }
            }
            .task(id: songToLocate) {
                if let songToLocate { await locateSong(songToLocate) }
            }
            .task(id: trackLocator.request) {
                await trackLocator.scroll(using: proxy, reduceMotion: reduceMotion)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .toolbar { playerToolbar }
        .toolbarVisibility(isEditing ? .hidden : .automatic, for: .tabBar)
        .onChange(of: isEditing) {
            setTabViewBottomAccessorySuppressed(isEditing)
        }
        .onAppear { setTabViewBottomAccessorySuppressed(isEditing) }
        .onDisappear { setTabViewBottomAccessorySuppressed(false) }
        .onChange(of: api.accountScope) {
            editingOperationID = nil
            isPreparingOrder = false
            isPerformingBatch = false
            draftOrder = nil
            reorderAccountScope = nil
            playlistSelection = nil
            selection.finishSelection()
        }
        .onChange(of: library.orderedFavoriteSongs.map(\.id)) { _, songIDs in
            selection.retainSelection(in: Set(songIDs))
            if let draftOrder {
                self.draftOrder = draftOrder.reconciled(with: songIDs, isComplete: !library.hasMoreFavoriteSongs)
            }
        }
        .confirmationDialog(
            L10n.format("ui.library.edit.remove_confirmation", selectedSongs.count),
            isPresented: $showsRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("ui.library.edit.remove_action", role: .destructive) { removeSelection() }
            Button("ui.common.cancel", role: .cancel) {}
        } message: {
            Text("ui.library.edit.remove_message")
        }
        .sheet(item: $playlistSelection) { request in
            AddToPlaylistSheet(songs: request.songs) { result in
                guard api.accountScope == request.accountScope else { return }
                selection.removeSelection(Set(result.succeededSongIDs))
                if selection.selectedSongIDs.isEmpty { selection.finishSelection() }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("ui.library.edit.failed", isPresented: Binding(
            get: { operationErrorMessage != nil || library.favoriteOrderErrorMessage != nil || downloadCoordinator.errorMessage != nil },
            set: { if !$0 { clearOperationError() } }
        )) {
            Button("ui.common.ok", role: .cancel) { clearOperationError() }
        } message: {
            Text(operationErrorMessage ?? library.favoriteOrderErrorMessage ?? downloadCoordinator.errorMessage ?? "")
        }
        .alert("ui.collection.locate_failed", isPresented: Binding(
            get: { locateErrorMessage != nil },
            set: { if !$0 { locateErrorMessage = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) { locateErrorMessage = nil }
        } message: {
            Text(locateErrorMessage ?? "")
        }
        .refreshable {
            guard !isEditing, !isBusy else { return }
            songToLocate = nil
            trackLocator.reset()
            await library.refresh(force: true)
            if isSearching { await prepareSearchResults(debounced: false) }
        }
        .overlay { emptyState }
        .task(id: LibrarySongSearchRequest(query: normalizedSearchQuery, reloadToken: searchReloadToken)) {
            await prepareSearchResults(debounced: true)
        }
        .alert("ui.library.heart_mode_failed", isPresented: Binding(
            get: { heartModeErrorMessage != nil },
            set: { if !$0 { heartModeErrorMessage = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) { heartModeErrorMessage = nil }
        } message: {
            Text(heartModeErrorMessage ?? L10n.string("ui.error.try_again_later"))
        }
        .alert("ui.library.play_all_failed", isPresented: Binding(
            get: { playbackErrorMessage != nil },
            set: { if !$0 { playbackErrorMessage = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            Text(playbackErrorMessage ?? L10n.string("ui.library.complete_song_list_failed"))
        }
    }

    @ViewBuilder
    private func songRow(_ song: Song) -> some View {
        if selection.isSelecting {
            Button {
                selection.toggleSelection(songID: song.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.selectedSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    TrackRowView(song: song, showsArtwork: true)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(song.name), \(song.artistText)")
            .accessibilityValue(L10n.string(
                selection.selectedSongIDs.contains(song.id)
                    ? "ui.library.edit.selected" : "ui.library.edit.not_selected"
            ))
            .accessibilityAddTraits(selection.selectedSongIDs.contains(song.id) ? .isSelected : [])
        } else if isReordering {
            TrackRowView(song: song, showsArtwork: true)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(song.name), \(song.artistText)")
                .accessibilityAction(named: L10n.string("ui.library.edit.move_up")) { moveSong(song.id, by: -1) }
                .accessibilityAction(named: L10n.string("ui.library.edit.move_down")) { moveSong(song.id, by: 1) }
        } else {
            Button {
                Task { await player.play(song, in: displayedSongs) }
            } label: {
                TrackRowView(song: song, showsArtwork: true)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { library.toggle(song: song) } label: {
                    Label("ui.common.unfavorite", systemImage: "heart.slash")
                }
                .disabled(library.pendingFavoriteSongIDs.contains(song.id))
            }
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        if isReordering {
            ToolbarItem(placement: .cancellationAction) {
                Button("ui.common.cancel") {
                    draftOrder = nil
                    reorderAccountScope = nil
                }
                .accessibilityIdentifier("favorites-order-cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("ui.library.edit.save_order", action: saveOrder)
                    .accessibilityIdentifier("favorites-order-save")
                    .disabled(isBusy)
            }
            ToolbarItem(placement: .bottomBar) {
                Text("ui.library.edit.order_local_note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if selection.isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("ui.common.done") { selection.finishSelection() }
                    .disabled(isBusy)
                    .accessibilityIdentifier("favorites-selection-done")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    selection.toggleAll(songIDs: Set(displayedSongs.map(\.id)))
                } label: {
                    Label(selectAllTitle, systemImage: hasSelectedAll ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(displayedSongs.isEmpty || isBusy)
                .accessibilityIdentifier("favorites-select-all")

                Spacer()
                Text(L10n.format("ui.library.edit.selected_count", selectedSongs.count))
                    .font(.subheadline.monospacedDigit())
                Spacer()

                if isBusy {
                    ProgressView().accessibilityLabel("ui.library.edit.processing")
                } else {
                    Menu {
                        Button("ui.playlists.add_to", systemImage: "text.badge.plus") {
                            playlistSelection = FavoritePlaylistSelection(songs: selectedSongs, accountScope: api.accountScope)
                        }
                        Button("ui.player.add_to_queue", systemImage: "text.badge.plus") {
                            player.addToPlaybackQueue(selectedSongs)
                            selection.finishSelection()
                        }
                        Button("ui.player.play_next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            playSelectionNext()
                        }
                        if AppFeatureAvailability.downloads {
                            Menu {
                                DownloadQualityButtons(action: downloadSelection)
                            } label: {
                                Label("ui.downloads.download_song", systemImage: "arrow.down.circle")
                            }
                        }
                        Divider()
                        Button("ui.library.edit.remove_action", systemImage: "heart.slash", role: .destructive) {
                            showsRemovalConfirmation = true
                        }
                    } label: {
                        Label("ui.library.edit.actions", systemImage: "ellipsis.circle")
                    }
                    .disabled(selectedSongs.isEmpty)
                    .accessibilityIdentifier("favorites-batch-actions")
                }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isPreparingOrder || songToLocate != nil {
                    ProgressView().accessibilityLabel(
                        isPreparingOrder ? "ui.library.edit.preparing_order" : "ui.collection.locating_playing"
                    )
                }
                Menu {
                    Button("ui.common.select_multiple", systemImage: "checklist") {
                        songToLocate = nil
                        trackLocator.reset()
                        selection.beginSelection()
                    }
                    .disabled(displayedSongs.isEmpty || isBusy)
                    Button("ui.library.edit.reorder", systemImage: "arrow.up.arrow.down") { beginReordering() }
                        .disabled(isSearching || library.favoriteSongs.isEmpty || isBusy || library.isUpdatingFavoriteSongs)
                    Divider()
                    Button("ui.collection.locate_playing", systemImage: "scope") { songToLocate = currentSongID }
                        .disabled(currentSongID == nil || songToLocate != nil || isPreparingSearchResults)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("ui.common.more")
                .accessibilityIdentifier("favorites-more")
                .disabled(isBusy)
            }
        }
    }

    private var isReordering: Bool { draftOrder != nil }
    private var isEditing: Bool { selection.isSelecting || isReordering }
    private var isBusy: Bool { isPreparingOrder || isPerformingBatch || downloadCoordinator.isPreparing }
    private var normalizedSearchQuery: String { normalizedLibrarySearchQuery(searchQuery) }
    private var isSearching: Bool { !normalizedSearchQuery.isEmpty }
    private var isPreparingSearchResults: Bool { searchPreparationID != nil }

    private var displayedSongs: [Song] {
        let songs = library.orderedFavoriteSongs
        let ordered: [Song]
        if let draftOrder {
            var byID: [Int: Song] = [:]
            for song in songs { byID[song.id] = song }
            ordered = draftOrder.applying(to: songs.map(\.id)).compactMap { byID[$0] }
        } else {
            ordered = songs
        }
        return filterMusicCollectionTracks(ordered, query: normalizedSearchQuery)
    }

    private var selectedSongs: [Song] {
        library.orderedFavoriteSongs.filter { selection.selectedSongIDs.contains($0.id) }
    }

    private var hasSelectedAll: Bool {
        let ids = Set(displayedSongs.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selection.selectedSongIDs)
    }

    private var selectAllTitle: String {
        if hasSelectedAll { return L10n.string("ui.common.deselect_all") }
        if isSearching { return L10n.string("ui.library.edit.select_search_results") }
        if library.hasMoreFavoriteSongs { return L10n.string("ui.library.edit.select_loaded") }
        return L10n.string("ui.common.select_all")
    }

    private func beginReordering() {
        guard !isSearching, !isBusy else { return }
        let operationID = UUID()
        let scope = api.accountScope
        editingOperationID = operationID
        isPreparingOrder = true
        operationErrorMessage = nil
        Task { @MainActor in
            defer {
                if editingOperationID == operationID { isPreparingOrder = false }
            }
            do {
                _ = try await library.favoriteSongsForPlayback()
                guard editingOperationID == operationID, api.accountScope == scope else { return }
                selection.finishSelection()
                trackLocator.reset()
                reorderAccountScope = scope
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    draftOrder = FavoriteSongOrder(songIDs: library.orderedFavoriteSongs.map(\.id))
                }
            } catch is CancellationError {
                return
            } catch {
                guard editingOperationID == operationID else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func moveSong(_ songID: Int, by distance: Int) {
        guard !isSearching, let draftOrder,
              let index = draftOrder.songIDs.firstIndex(of: songID) else { return }
        let target = index + distance
        guard draftOrder.songIDs.indices.contains(target) else { return }
        self.draftOrder = draftOrder.moving(
            fromOffsets: IndexSet(integer: index),
            toOffset: target > index ? target + 1 : target
        )
    }

    private func saveOrder() {
        guard let draftOrder, let reorderAccountScope else { return }
        do {
            try library.saveFavoriteSongOrder(draftOrder.songIDs, accountScope: reorderAccountScope)
            self.draftOrder = nil
            self.reorderAccountScope = nil
        } catch is CancellationError {
            self.draftOrder = nil
            self.reorderAccountScope = nil
        } catch {
            operationErrorMessage = library.favoriteOrderErrorMessage ?? error.localizedDescription
        }
    }

    private func removeSelection() {
        let songs = selectedSongs
        guard !songs.isEmpty, !isBusy else { return }
        let operationID = UUID()
        let scope = api.accountScope
        editingOperationID = operationID
        isPerformingBatch = true
        Task { @MainActor in
            defer {
                if editingOperationID == operationID { isPerformingBatch = false }
            }
            let result = await library.removeFavoriteSongs(songs)
            guard editingOperationID == operationID, api.accountScope == scope else { return }
            selection.removeSelection(Set(result.succeededSongIDs))
            if result.isComplete {
                selection.finishSelection()
            } else {
                operationErrorMessage = result.errorMessage
            }
        }
    }

    private func playSelectionNext() {
        let songs = selectedSongs
        guard !songs.isEmpty, !isBusy else { return }
        let scope = api.accountScope
        isPerformingBatch = true
        Task { @MainActor in
            defer { isPerformingBatch = false }
            await player.playNext(songs)
            guard api.accountScope == scope else { return }
            selection.finishSelection()
        }
    }

    private func downloadSelection(_ quality: MusicQuality) {
        let songs = selectedSongs
        guard !songs.isEmpty, !isBusy else { return }
        let scope = api.accountScope
        Task { @MainActor in
            await downloadCoordinator.downloadAll(in: songs, quality: quality, api: api, downloads: downloads)
            guard api.accountScope == scope else { return }
            if downloadCoordinator.errorMessage == nil { selection.finishSelection() }
        }
    }

    private func clearOperationError() {
        operationErrorMessage = nil
        library.clearFavoriteOrderError()
        downloadCoordinator.clearError()
    }

    private var currentSongID: Int? {
        guard let song = player.currentSong, library.contains(song: song),
              !filterMusicCollectionTracks([song], query: normalizedSearchQuery).isEmpty else { return nil }
        return song.id
    }

    private func locateSong(_ songID: Int) async {
        defer { songToLocate = nil }
        locateErrorMessage = nil
        let isLoaded = await library.loadFavoriteSongForLocation(songID)
        guard !Task.isCancelled else { return }
        guard isLoaded else {
            locateErrorMessage = library.favoriteSongsLoadMoreError ?? L10n.string("ui.collection.locate_unavailable")
            return
        }
        guard displayedSongs.contains(where: { $0.id == songID }) else { return }
        trackLocator.locate(songID)
    }

    private var heartModeButton: some View {
        Button(action: startHeartMode) {
            HStack {
                Label("ui.home.action.heart_mode", systemImage: "heart.circle.fill")
                Spacer()
                if isStartingHeartMode { ProgressView().controlSize(.small) }
            }
        }
        .disabled(!library.canStartHeartMode || isStartingHeartMode)
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if isSearching {
            if isPreparingSearchResults {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("ui.library.searching_all_favorite_songs").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowSeparator(.hidden)
            } else if let failureMessage = library.favoriteSongsLoadMoreError, library.hasMoreFavoriteSongs {
                VStack(spacing: 8) {
                    Text(failureMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("ui.library.search_again") { searchReloadToken += 1 }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowSeparator(.hidden)
            }
        } else if library.hasMoreFavoriteSongs {
            MusicCollectionPaginationFooter(
                isLoading: library.isLoadingMoreFavoriteSongs,
                failureMessage: library.favoriteSongsLoadMoreError,
                loadToken: library.favoriteSongsNextOffset,
                action: { await library.loadMoreFavoriteSongs() }
            )
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if displayedSongs.isEmpty, !isPreparingSearchResults, !hasSearchLoadFailure {
            if isSearching {
                ContentUnavailableView.search(text: normalizedSearchQuery)
            } else if !library.hasMoreFavoriteSongs {
                ContentUnavailableView("ui.library.no_favorite_songs", systemImage: "heart", description: Text("ui.library.no_favorite_songs.message"))
            }
        }
    }

    private var hasSearchLoadFailure: Bool {
        isSearching && library.favoriteSongsLoadMoreError != nil && library.hasMoreFavoriteSongs
    }

    private func prepareSearchResults(debounced: Bool) async {
        guard isSearching else {
            searchPreparationID = nil
            return
        }
        guard library.hasMoreFavoriteSongs else { return }
        let preparationID = UUID()
        searchPreparationID = preparationID
        defer { if searchPreparationID == preparationID { searchPreparationID = nil } }
        if debounced {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await library.loadRemainingFavoriteSongs()
    }

    private func startHeartMode() {
        guard !isStartingHeartMode, let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else { return }
        isStartingHeartMode = true
        heartModeErrorMessage = nil
        Task { @MainActor in
            defer { isStartingHeartMode = false }
            do { try await player.playHeartMode(playlistID: playlistID, seedSongID: seedSongID) }
            catch is CancellationError { return }
            catch { heartModeErrorMessage = error.localizedDescription }
        }
    }

    private func playDisplayedSongs() {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        playbackErrorMessage = nil
        Task { @MainActor in
            defer { isPreparingPlayback = false }
            do {
                let songs = if isSearching { displayedSongs } else { try await library.favoriteSongsForPlayback() }
                try Task.checkCancellation()
                await player.playAll(songs)
            } catch is CancellationError { return }
            catch { playbackErrorMessage = error.localizedDescription }
        }
    }
}

private struct LibrarySongSearchRequest: Hashable {
    let query: String
    let reloadToken: Int
}

private struct FavoritePlaylistSelection: Identifiable {
    let id = UUID()
    let songs: [Song]
    let accountScope: String
}
