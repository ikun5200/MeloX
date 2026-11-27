import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    private(set) var profile: AccountProfile?
    private(set) var accountDetail: AccountDetail?
    private(set) var favoriteSongs: [Song] = []
    private(set) var favoritePlaylists: [Playlist] = []
    private(set) var favoriteAlbums: [Album] = []
    private(set) var favoriteArtists: [Artist] = []
    private(set) var subscribedPodcasts: [Podcast] = []
    private(set) var recentSongs: [Song] = []
    private(set) var likedPlaylistID: Int?
    private(set) var favoriteSongTotalCount = 0
    private(set) var favoriteSongsNextOffset = 0
    private(set) var isLoadingMoreFavoriteSongs = false
    private(set) var favoriteSongsLoadMoreError: String?
    private(set) var subscribedPodcastTotalCount = 0
    private(set) var subscribedPodcastsNextOffset = 0
    private(set) var hasMoreSubscribedPodcasts = false
    private(set) var isLoadingMoreSubscribedPodcasts = false
    private(set) var subscribedPodcastsLoadMoreError: String?
    private(set) var phase: LoadingPhase = .loaded
    private(set) var errorMessage: String?
    private(set) var favoriteOrderErrorMessage: String?
    private(set) var pendingFavoriteSongIDs: Set<Int> = []
    private(set) var isPerformingFavoriteBatch = false
    private var favoriteSongOrder: FavoriteSongOrder?
    private var qqFavoriteSongsHaveMore = false

    @ObservationIgnored
    private let orderStore: FavoriteSongOrderStore

    @ObservationIgnored
    private var favoriteContentRevision: UInt64 = 0

    @ObservationIgnored
    private var favoriteBatchID: UUID?

    @ObservationIgnored
    private let api: NeteaseAPI

    @ObservationIgnored
    private let settings: AppSettings

    @ObservationIgnored
    private var loadedCookie: String?

    @ObservationIgnored
    private var lastSuccessfulRefresh: Date?

    @ObservationIgnored
    private var refreshingCookie: String?

    @ObservationIgnored
    private var favoriteSongIDs: [Int] = []

    @ObservationIgnored
    private var favoriteSongIDSet: Set<Int> = []

    @ObservationIgnored
    private let favoriteSongPageSize = 100

    @ObservationIgnored
    private var favoriteSongPageLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var favoriteSongPageLoadID: UUID?

    @ObservationIgnored
    private let subscribedPodcastPageSize = 50

    @ObservationIgnored
    private var subscribedPodcastPageLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var subscribedPodcastPageLoadID: UUID?

    init(
        api: NeteaseAPI,
        settings: AppSettings,
        orderStore: FavoriteSongOrderStore = FavoriteSongOrderStore()
    ) {
        self.api = api
        self.settings = settings
        self.orderStore = orderStore
    }

    var orderedFavoriteSongs: [Song] {
        var songsByID: [Int: Song] = [:]
        for song in favoriteSongs where songsByID[song.id] == nil {
            songsByID[song.id] = song
        }
        let remoteIDs = FavoriteSongOrder.uniqueIDs(favoriteSongs.map(\.id))
        let orderedIDs = favoriteSongOrder?.applying(to: remoteIDs) ?? remoteIDs
        return orderedIDs.compactMap { songsByID[$0] }
    }

    var isUpdatingFavoriteSongs: Bool {
        isPerformingFavoriteBatch || !pendingFavoriteSongIDs.isEmpty
    }

    func saveFavoriteSongOrder(_ songIDs: [Int], accountScope: String) throws {
        guard isLoggedIn, api.accountScope == accountScope,
              loadedCookie == accountScope else { throw CancellationError() }
        guard !hasMoreFavoriteSongs else { throw FavoriteSongOrderError.incompleteLibrary }
        let order = FavoriteSongOrder(songIDs: songIDs)
            .reconciled(with: favoriteSongIDs, isComplete: true)
        do {
            try orderStore.save(order, accountScope: accountScope)
            favoriteSongOrder = order
            favoriteOrderErrorMessage = nil
        } catch {
            favoriteOrderErrorMessage = L10n.format("ui.library.edit.order_save_failed", error.localizedDescription)
            throw error
        }
    }

    func clearFavoriteOrderError() {
        favoriteOrderErrorMessage = nil
    }

    var isLoggedIn: Bool {
        api.hasAccount
    }

    var ownedPlaylists: [Playlist] {
        guard let userID = profile?.id else { return [] }
        return favoritePlaylists.filter { $0.creator?.userID == userID }
    }

    var hasMoreFavoriteSongs: Bool {
        api.isUsingSourceResolver
            ? qqFavoriteSongsHaveMore
            : favoriteSongsNextOffset < favoriteSongTotalCount
    }

    var canStartHeartMode: Bool {
        likedPlaylistID != nil && favoriteSongTotalCount > 0
    }

    func randomHeartModeSeedSongID() -> Int? {
        favoriteSongIDs.randomElement()
    }

    func contains(song: Song) -> Bool {
        favoriteSongIDSet.contains(song.id)
    }

    func contains(playlist: Playlist) -> Bool {
        favoritePlaylists.contains { $0.id == playlist.id }
    }

    func contains(artist: Artist) -> Bool {
        favoriteArtists.contains { $0.id == artist.id }
    }

    func contains(album: Album) -> Bool {
        favoriteAlbums.contains { $0.id == album.id }
    }

    func setArtistFollowed(_ artist: Artist, isFollowed: Bool) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        try await api.setArtistFollowed(id: artist.id, isFollowed: isFollowed)
        favoriteArtists.removeAll { $0.id == artist.id }
        if isFollowed {
            favoriteArtists.insert(artist, at: 0)
        }
        await persistContent()
    }

    func setAlbumSubscribed(
        _ album: Album,
        isSubscribed: Bool
    ) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        try await api.setAlbumSubscribed(id: album.id, isSubscribed: isSubscribed)
        favoriteAlbums.removeAll { $0.id == album.id }
        if isSubscribed {
            favoriteAlbums.insert(album, at: 0)
        }
        await persistContent()
    }

    func contains(podcast: Podcast) -> Bool {
        subscribedPodcasts.contains { $0.id == podcast.id }
    }

    func recordRecentlyPlayed(_ song: Song) {
        guard settings.isContentFeatureEnabled(.listeningHistory) else {
            return
        }
        recentSongs.removeAll { $0.id == song.id }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 100 {
            recentSongs.removeLast(recentSongs.count - 100)
        }
        persistContentInBackground()
    }

    func canUnsubscribe(_ playlist: Playlist) -> Bool {
        playlist.creator?.userID != profile?.id
    }

    func refresh(force: Bool = false) async {
        let cookie = api.accountScope
        guard !cookie.isEmpty else {
            clearAccountData()
            return
        }
        guard refreshingCookie != cookie else { return }
        let isFresh = lastSuccessfulRefresh.map {
            Date().timeIntervalSince($0) < 300
        } ?? false
        guard force || loadedCookie != cookie || phase != .loaded || !isFresh else { return }
        refreshingCookie = cookie
        defer {
            if refreshingCookie == cookie {
                refreshingCookie = nil
            }
        }

        if loadedCookie != cookie {
            clearRemoteContent()
            loadedCookie = cookie
            if let snapshot: LibraryContentSnapshot = await api.pageContentCache.value(
                for: LibraryContentSnapshot.cacheKey
            ) {
                restoreContent(snapshot)
            }
            guard isCurrentRefresh(cookie) else { return }
        }
        loadFavoriteSongOrder(accountScope: cookie)
        phase = .loading
        errorMessage = nil
        favoriteSongsLoadMoreError = nil
        subscribedPodcastsLoadMoreError = nil

        do {
            let loadedProfile = try await api.accountProfile()
            guard isCurrentRefresh(cookie) else { return }

            profile = loadedProfile
            loadedCookie = cookie

            var partialFailures: [String] = []
            do {
                let loadedAccountDetail = try await api.userDetail(
                    userID: loadedProfile.id
                )
                guard isCurrentRefresh(cookie) else { return }
                accountDetail = loadedAccountDetail
                profile = loadedAccountDetail.profile
            } catch is CancellationError {
                return
            } catch {
                // The account endpoint still provides enough identity data
                // for the settings row when extended profile details fail.
            }

            var loadedPlaylists: [Playlist] = []
            do {
                loadedPlaylists = try await api.userPlaylists(userID: loadedProfile.id)
                guard isCurrentRefresh(cookie) else { return }
                if api.isUsingSourceResolver {
                    // QQ 的“我喜欢”不放在歌单列表里，单独用 dirid 201 获取。
                    likedPlaylistID = 0
                    favoritePlaylists = loadedPlaylists
                } else {
                    // 网易云把“我喜欢的音乐”作为返回列表的第一项；参考项目
                    // 同样在歌单页隐藏这一项，歌曲页单独展示其中的歌曲。
                    likedPlaylistID = loadedPlaylists.first?.id
                    favoritePlaylists = Array(loadedPlaylists.dropFirst())
                }
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(L10n.format("ui.library.error.playlists", error.localizedDescription))
            }

            do {
                let albums = try await api.subscribedAlbums()
                guard isCurrentRefresh(cookie) else { return }
                favoriteAlbums = albums
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(
                    L10n.format("ui.library.error.favorite_albums", error.localizedDescription)
                )
            }

            do {
                let artists = try await api.subscribedArtists()
                guard isCurrentRefresh(cookie) else { return }
                favoriteArtists = artists
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(
                    L10n.format("ui.library.error.favorite_artists", error.localizedDescription)
                )
            }

            do {
                let revision = favoriteContentRevision
                if api.isUsingSourceResolver {
                    let page = try await api.sourceLikedSongsPage(limit: favoriteSongPageSize)
                    guard isCurrentRefresh(cookie) else { return }
                    if favoriteContentRevision == revision {
                        favoriteSongIDs = FavoriteSongOrder.uniqueIDs(page.songs.map(\.id))
                        favoriteSongIDSet = Set(favoriteSongIDs)
                        favoriteSongTotalCount = page.totalCount
                        favoriteSongs = uniqueFavoriteSongs(page.songs)
                        favoriteSongsNextOffset = page.nextOffset
                        qqFavoriteSongsHaveMore = page.hasMore
                        favoriteSongsLoadMoreError = nil
                        reconcileFavoriteSongOrder(isComplete: !page.hasMore)
                        await loadRemainingFavoriteSongs()
                        guard isCurrentRefresh(cookie) else { return }
                        if let error = favoriteSongsLoadMoreError {
                            partialFailures.append(L10n.format("ui.library.error.favorite_songs", error))
                        }
                    }
                } else {
                    let loadedSongIDs = try await api.likedSongIDs(
                        userID: loadedProfile.id,
                        likedPlaylistID: likedPlaylistID
                    )
                    let firstPage = try await api.songDetailsPage(
                        ids: loadedSongIDs,
                        offset: 0,
                        limit: favoriteSongPageSize
                    )
                    guard isCurrentRefresh(cookie) else { return }
                    guard loadedSongIDs.isEmpty || !firstPage.songs.isEmpty else {
                        throw APIError.invalidResponse
                    }
                    if favoriteContentRevision == revision {
                        favoriteSongIDs = loadedSongIDs
                        favoriteSongIDSet = Set(loadedSongIDs)
                        favoriteSongTotalCount = loadedSongIDs.count
                        favoriteSongs = firstPage.songs
                        favoriteSongsNextOffset = firstPage.nextOffset
                        favoriteSongsLoadMoreError = nil
                        reconcileFavoriteSongOrder(isComplete: true)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(L10n.format("ui.library.error.favorite_songs", error.localizedDescription))
            }

            if settings.isContentFeatureEnabled(.listeningHistory),
               !api.isUsingSourceResolver {
                do {
                    let songs = try await api.recentSongs()
                    guard isCurrentRefresh(cookie) else { return }
                    recentSongs = songs
                } catch is CancellationError {
                    return
                } catch {
                    partialFailures.append(
                        L10n.format("ui.library.error.history", error.localizedDescription)
                    )
                }
            }

            guard isCurrentRefresh(cookie) else { return }
            if !partialFailures.isEmpty {
                errorMessage = L10n.format(
                    "ui.library.error.partial",
                    partialFailures.joined(separator: "\n")
                )
            }
            lastSuccessfulRefresh = partialFailures.isEmpty ? Date() : nil
            phase = .loaded
            await persistContent()
        } catch is CancellationError {
            return
        } catch APIError.notLoggedIn {
            guard isCurrentRefresh(cookie) else { return }
            api.clearAccount()
            clearAccountData()
        } catch {
            guard isCurrentRefresh(cookie) else { return }
            lastSuccessfulRefresh = nil
            if profile == nil {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .loaded
                errorMessage = L10n.format("ui.library.error.account_refresh", error.localizedDescription)
            }
        }
    }

    private func isCurrentRefresh(_ cookie: String) -> Bool {
        !Task.isCancelled && refreshingCookie == cookie
            && api.accountScope == cookie
    }

    func loadMoreFavoriteSongs() async {
        if let favoriteSongPageLoadTask {
            await favoriteSongPageLoadTask.value
            return
        }

        guard hasMoreFavoriteSongs else { return }

        let requestedOffset = favoriteSongsNextOffset
        let requestedIDs = favoriteSongIDs
        let requestedScope = api.accountScope
        let requestedRevision = favoriteContentRevision
        let loadID = UUID()
        let loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFavoriteSongsPage(
                ids: requestedIDs,
                offset: requestedOffset,
                accountScope: requestedScope,
                revision: requestedRevision
            )
        }
        favoriteSongPageLoadID = loadID
        favoriteSongPageLoadTask = loadTask

        await loadTask.value

        guard favoriteSongPageLoadID == loadID else { return }
        favoriteSongPageLoadTask = nil
        favoriteSongPageLoadID = nil
    }

    func loadFavoriteSongForLocation(_ songID: Int) async -> Bool {
        if favoriteSongs.contains(where: { $0.id == songID }) { return true }
        if api.isUsingSourceResolver {
            let scope = api.accountScope
            while hasMoreFavoriteSongs {
                guard !Task.isCancelled, api.accountScope == scope else { return false }
                let previousOffset = favoriteSongsNextOffset
                await loadMoreFavoriteSongs()
                guard api.accountScope == scope else { return false }
                if favoriteSongs.contains(where: { $0.id == songID }) { return true }
                guard favoriteSongsNextOffset > previousOffset else { return false }
            }
            return false
        }
        let requestedIDs = favoriteSongIDs
        guard let index = requestedIDs.firstIndex(of: songID) else { return false }

        while favoriteSongsNextOffset <= index, hasMoreFavoriteSongs {
            guard !Task.isCancelled else { return false }
            let previousOffset = favoriteSongsNextOffset
            await loadMoreFavoriteSongs()
            guard !Task.isCancelled,
                  favoriteSongIDs == requestedIDs,
                  favoriteSongsNextOffset > previousOffset else { return false }
        }
        return favoriteSongs.contains(where: { $0.id == songID })
    }

    func loadRemainingFavoriteSongs() async {
        while hasMoreFavoriteSongs {
            guard !Task.isCancelled else { return }
            let previousOffset = favoriteSongsNextOffset
            await loadMoreFavoriteSongs()
            guard favoriteSongsNextOffset > previousOffset else { return }
        }
    }

    func favoriteSongsForPlayback() async throws -> [Song] {
        let scope = api.accountScope
        await loadRemainingFavoriteSongs()
        try Task.checkCancellation()
        guard api.accountScope == scope else { throw CancellationError() }
        guard !hasMoreFavoriteSongs else {
            throw LibraryOperationError.favoriteSongsIncomplete(
                favoriteSongsLoadMoreError ?? L10n.string("ui.library.complete_song_list_failed")
            )
        }
        if api.isUsingSourceResolver { return orderedFavoriteSongs }

        let requestedIDs = favoriteSongIDs
        let songs = try await api.songDetailsCollection(
            ids: requestedIDs,
            prefetched: favoriteSongs
        )
        try Task.checkCancellation()
        guard api.accountScope == scope, favoriteSongIDs == requestedIDs else {
            throw CancellationError()
        }
        favoriteSongs = songs
        favoriteSongsNextOffset = requestedIDs.count
        favoriteSongsLoadMoreError = nil
        return orderedFavoriteSongs
    }

    private func loadFavoriteSongsPage(
        ids requestedIDs: [Int],
        offset requestedOffset: Int,
        accountScope: String,
        revision: UInt64
    ) async {
        guard api.accountScope == accountScope, favoriteContentRevision == revision else { return }
        isLoadingMoreFavoriteSongs = true
        favoriteSongsLoadMoreError = nil
        defer {
            if api.accountScope == accountScope, favoriteContentRevision == revision {
                isLoadingMoreFavoriteSongs = false
            }
        }

        do {
            let page = if api.isUsingSourceResolver {
                try await api.sourceLikedSongsPage(offset: requestedOffset, limit: favoriteSongPageSize)
            } else {
                try await api.songDetailsPage(
                    ids: requestedIDs,
                    offset: requestedOffset,
                    limit: favoriteSongPageSize
                )
            }
            try Task.checkCancellation()
            guard api.accountScope == accountScope,
                  favoriteContentRevision == revision,
                  favoriteSongIDs == requestedIDs,
                  favoriteSongsNextOffset == requestedOffset else { return }
            guard page.nextOffset > requestedOffset || !page.hasMore else {
                throw APIError.invalidResponse
            }

            var loadedIDs = Set(favoriteSongs.map(\.id))
            let addedSongs = page.songs.filter { $0.id > 0 && loadedIDs.insert($0.id).inserted }
            favoriteSongs.append(contentsOf: addedSongs)
            if api.isUsingSourceResolver {
                favoriteSongIDs.append(contentsOf: addedSongs.map(\.id))
                favoriteSongIDSet.formUnion(addedSongs.map(\.id))
                favoriteSongTotalCount = page.totalCount
                qqFavoriteSongsHaveMore = page.hasMore
            }
            favoriteSongsNextOffset = page.nextOffset
            reconcileFavoriteSongOrder(isComplete: !hasMoreFavoriteSongs)
            await persistContent()
        } catch is CancellationError {
            return
        } catch {
            guard api.accountScope == accountScope, favoriteContentRevision == revision else { return }
            favoriteSongsLoadMoreError = error.localizedDescription
        }
    }

    func loadMoreSubscribedPodcasts() async {
        return
    }

    func loadRemainingSubscribedPodcasts() async {
        while hasMoreSubscribedPodcasts {
            guard !Task.isCancelled else { return }
            let previousOffset = subscribedPodcastsNextOffset
            await loadMoreSubscribedPodcasts()
            guard subscribedPodcastsNextOffset > previousOffset else {
                return
            }
        }
    }

    private func loadSubscribedPodcastPage(
        offset requestedOffset: Int
    ) async {
        isLoadingMoreSubscribedPodcasts = true
        subscribedPodcastsLoadMoreError = nil
        defer { isLoadingMoreSubscribedPodcasts = false }

        do {
            let page = try await api.subscribedPodcasts(
                offset: requestedOffset,
                limit: subscribedPodcastPageSize
            )
            try Task.checkCancellation()
            guard subscribedPodcastsNextOffset == requestedOffset else {
                return
            }

            var loadedIDs = Set(subscribedPodcasts.map(\.id))
            subscribedPodcasts.append(
                contentsOf: normalizedSubscribedPodcasts(
                    page.podcasts
                ).filter {
                    loadedIDs.insert($0.id).inserted
                }
            )
            subscribedPodcastsNextOffset =
                requestedOffset + page.podcasts.count
            subscribedPodcastTotalCount = max(
                page.totalCount ?? subscribedPodcastTotalCount,
                subscribedPodcasts.count
            )
            hasMoreSubscribedPodcasts =
                page.hasMore && !page.podcasts.isEmpty
            await persistContent()
        } catch is CancellationError {
            return
        } catch {
            subscribedPodcastsLoadMoreError =
                error.localizedDescription
        }
    }

    func toggle(song: Song) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }
        guard !isPerformingFavoriteBatch, !pendingFavoriteSongIDs.contains(song.id) else { return }
        let scope = api.accountScope
        let desiredState = !contains(song: song)
        pendingFavoriteSongIDs.insert(song.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.api.accountScope == scope {
                    self.pendingFavoriteSongIDs.remove(song.id)
                }
            }
            do {
                try await self.api.setSongLiked(id: song.id, isLiked: desiredState)
                guard self.api.accountScope == scope else { return }
                // Change membership only after QQ confirms it. A failed
                // cancellation therefore leaves the song at its exact position.
                self.setLocalSong(song, isLiked: desiredState)
            } catch is CancellationError {
                return
            } catch {
                guard self.api.accountScope == scope else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func removeFavoriteSongs(_ songs: [Song]) async -> LibrarySongBatchResult {
        let songs = uniqueFavoriteSongs(songs)
        guard !isUpdatingFavoriteSongs else {
            return failedBatch(songs, message: L10n.string("ui.library.edit.operation_in_progress"))
        }
        let scope = api.accountScope
        let operationID = UUID()
        favoriteBatchID = operationID
        isPerformingFavoriteBatch = true
        pendingFavoriteSongIDs.formUnion(songs.map(\.id))
        defer {
            if favoriteBatchID == operationID {
                pendingFavoriteSongIDs.subtract(songs.map(\.id))
                isPerformingFavoriteBatch = false
                favoriteBatchID = nil
            }
        }
        return await performSongBatch(songs) { song in
            try await self.api.setSongLiked(id: song.id, isLiked: false)
            guard self.api.accountScope == scope else { throw CancellationError() }
            self.setLocalSong(song, isLiked: false)
        }
    }

    func toggle(playlist: Playlist) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }

        let wasSubscribed = contains(playlist: playlist)
        guard !wasSubscribed || canUnsubscribe(playlist) else { return }
        if wasSubscribed {
            favoritePlaylists.removeAll { $0.id == playlist.id }
        } else {
            var summary = playlist
            summary.tracks = []
            favoritePlaylists.insert(summary, at: 0)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.api.setPlaylistSubscribed(
                    id: playlist.id,
                    isSubscribed: !wasSubscribed
                )
            } catch {
                if wasSubscribed {
                    self.favoritePlaylists.insert(playlist, at: 0)
                } else {
                    self.favoritePlaylists.removeAll { $0.id == playlist.id }
                }
                self.errorMessage = error.localizedDescription
            }
            await self.persistContent()
        }
    }

    func toggle(podcast: Podcast) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }

        let desiredState = !contains(podcast: podcast)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.setPodcastSubscribed(
                    podcast,
                    isSubscribed: desiredState
                )
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setPodcastSubscribed(
        _ podcast: Podcast,
        isSubscribed: Bool
    ) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }

        let previousPodcasts = subscribedPodcasts
        let previousTotalCount = subscribedPodcastTotalCount
        let previousNextOffset = subscribedPodcastsNextOffset
        let previousHasMore = hasMoreSubscribedPodcasts
        setLocalPodcast(podcast, isSubscribed: isSubscribed)

        do {
            try await api.setPodcastSubscribed(
                id: podcast.id,
                isSubscribed: isSubscribed
            )
        } catch {
            subscribedPodcasts = previousPodcasts
            subscribedPodcastTotalCount = previousTotalCount
            subscribedPodcastsNextOffset = previousNextOffset
            hasMoreSubscribedPodcasts = previousHasMore
            await persistContent()
            throw error
        }
    }

    func canDelete(_ playlist: Playlist) -> Bool {
        guard isLoggedIn, let userID = profile?.id else { return false }
        return playlist.creator?.userID == userID && playlist.id != likedPlaylistID
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard canDelete(playlist) else { throw LibraryOperationError.playlistIsNotOwned }
        try await api.deletePlaylist(id: playlist.id, dirid: playlist.dirid)
        favoritePlaylists.removeAll { $0.id == playlist.id }
        await persistContent()
    }

    func createPlaylist(name: String, isPrivate: Bool) async throws {
        guard isLoggedIn, let profile else { throw APIError.notLoggedIn }
        let created = try await api.createPlaylist(name: name, isPrivate: isPrivate)
        let summary = Playlist(
            id: created.id,
            name: created.name,
            coverURLString: created.coverURLString,
            creator: UserSummary(userID: profile.id, nickname: profile.nickname),
            dirid: created.dirid
        )
        favoritePlaylists.insert(summary, at: 0)
        await persistContent()
    }

    func remove(song: Song, from playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard canDelete(playlist) else { throw LibraryOperationError.playlistIsNotOwned }
        try await api.removeSong(
            id: song.id,
            fromPlaylistID: playlist.id,
            dirid: playlist.dirid
        )
        if let index = favoritePlaylists.firstIndex(where: { $0.id == playlist.id }) {
            favoritePlaylists[index].removeSong(id: song.id)
        }
        await persistContent()
    }

    func add(song: Song, to playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard playlist.creator?.userID == profile?.id else {
            throw LibraryOperationError.playlistIsNotOwned
        }
        try await api.addSong(
            id: song.id,
            toPlaylistID: playlist.id,
            dirid: playlist.dirid
        )
    }

    func add(songs: [Song], to playlist: Playlist) async -> LibrarySongBatchResult {
        guard playlist.creator?.userID == profile?.id else {
            return failedBatch(songs, message: LibraryOperationError.playlistIsNotOwned.localizedDescription)
        }
        return await performSongBatch(uniqueFavoriteSongs(songs)) { song in
            try await self.add(song: song, to: playlist)
        }
    }

    private func performSongBatch(
        _ songs: [Song],
        operation: (Song) async throws -> Void
    ) async -> LibrarySongBatchResult {
        guard isLoggedIn else {
            return failedBatch(songs, message: APIError.notLoggedIn.localizedDescription)
        }
        let scope = api.accountScope
        var succeeded: [Int] = []
        var failures: [LibrarySongBatchResult.Failure] = []
        for (index, song) in songs.enumerated() {
            do {
                try Task.checkCancellation()
                guard api.accountScope == scope else { throw CancellationError() }
                try await operation(song)
                guard api.accountScope == scope else { throw CancellationError() }
                succeeded.append(song.id)
            } catch is CancellationError {
                let message = L10n.string("ui.library.edit.operation_interrupted")
                failures.append(contentsOf: songs[index...].map { .init(songID: $0.id, message: message) })
                break
            } catch {
                failures.append(.init(songID: song.id, message: error.localizedDescription))
                if let error = error as? QQMusicError,
                   error.isAuthenticationFailure || error.isRateLimited {
                    failures.append(contentsOf: songs.dropFirst(index + 1).map {
                        .init(songID: $0.id, message: error.localizedDescription)
                    })
                    break
                }
            }
        }
        return LibrarySongBatchResult(succeededSongIDs: succeeded, failures: failures)
    }

    private func failedBatch(_ songs: [Song], message: String) -> LibrarySongBatchResult {
        LibrarySongBatchResult(
            succeededSongIDs: [],
            failures: uniqueFavoriteSongs(songs).map { .init(songID: $0.id, message: message) }
        )
    }

    func clearAccountData() {
        if let cookie = loadedCookie {
            let cache = api.pageContentCache
            let scope = cookie
            Task { await cache.removeAccount(scope: scope) }
        }
        loadedCookie = nil
        clearRemoteContent()
        phase = .loaded
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func clearRemoteContent() {
        lastSuccessfulRefresh = nil
        favoriteContentRevision &+= 1
        favoriteSongOrder = nil
        qqFavoriteSongsHaveMore = false
        favoriteOrderErrorMessage = nil
        pendingFavoriteSongIDs.removeAll()
        isPerformingFavoriteBatch = false
        favoriteBatchID = nil
        favoriteSongPageLoadTask?.cancel()
        favoriteSongPageLoadTask = nil
        favoriteSongPageLoadID = nil
        subscribedPodcastPageLoadTask?.cancel()
        subscribedPodcastPageLoadTask = nil
        subscribedPodcastPageLoadID = nil
        profile = nil
        accountDetail = nil
        favoriteSongs = []
        favoritePlaylists = []
        favoriteAlbums = []
        favoriteArtists = []
        subscribedPodcasts = []
        recentSongs = []
        likedPlaylistID = nil
        favoriteSongIDs = []
        favoriteSongIDSet = []
        favoriteSongTotalCount = 0
        favoriteSongsNextOffset = 0
        isLoadingMoreFavoriteSongs = false
        favoriteSongsLoadMoreError = nil
        subscribedPodcastTotalCount = 0
        subscribedPodcastsNextOffset = 0
        hasMoreSubscribedPodcasts = false
        isLoadingMoreSubscribedPodcasts = false
        subscribedPodcastsLoadMoreError = nil
    }

    private func setLocalSong(
        _ song: Song,
        isLiked: Bool
    ) {
        guard contains(song: song) != isLiked else { return }
        favoriteContentRevision &+= 1
        favoriteSongPageLoadTask?.cancel()
        favoriteSongPageLoadTask = nil
        favoriteSongPageLoadID = nil
        isLoadingMoreFavoriteSongs = false
        if let index = favoriteSongIDs.firstIndex(of: song.id) {
            favoriteSongIDs.remove(at: index)
            if index < favoriteSongsNextOffset {
                favoriteSongsNextOffset = max(favoriteSongsNextOffset - 1, 0)
            }
        }
        favoriteSongIDSet.remove(song.id)
        favoriteSongs.removeAll { $0.id == song.id }

        if isLiked {
            favoriteSongIDs.insert(song.id, at: 0)
            favoriteSongIDSet.insert(song.id)
            favoriteSongs.insert(song, at: 0)
            favoriteSongsNextOffset += 1
        }
        favoriteSongTotalCount = max(
            favoriteSongTotalCount + (isLiked ? 1 : -1),
            favoriteSongIDs.count
        )
        if let order = favoriteSongOrder {
            persistFavoriteSongOrder(isLiked ? order.adding(song.id) : order.removing(song.id))
        }
        persistContentInBackground()
    }

    private func uniqueFavoriteSongs(_ songs: [Song]) -> [Song] {
        var seen: Set<Int> = []
        return songs.filter { $0.id > 0 && seen.insert($0.id).inserted }
    }

    private func loadFavoriteSongOrder(accountScope: String) {
        do {
            favoriteSongOrder = try orderStore.load(accountScope: accountScope)
            favoriteOrderErrorMessage = nil
        } catch {
            favoriteOrderErrorMessage = L10n.format("ui.library.edit.order_read_detail", error.localizedDescription)
        }
    }

    private func reconcileFavoriteSongOrder(isComplete: Bool) {
        guard let order = favoriteSongOrder else { return }
        let reconciled = order.reconciled(with: favoriteSongIDs, isComplete: isComplete)
        guard reconciled != order else { return }
        persistFavoriteSongOrder(reconciled)
    }

    private func persistFavoriteSongOrder(_ order: FavoriteSongOrder) {
        let scope = api.accountScope
        guard !scope.isEmpty, loadedCookie == scope else { return }
        do {
            try orderStore.save(order, accountScope: scope)
            favoriteSongOrder = order
            favoriteOrderErrorMessage = nil
        } catch {
            favoriteOrderErrorMessage = L10n.format("ui.library.edit.order_save_failed", error.localizedDescription)
        }
    }

    private func setLocalPodcast(
        _ podcast: Podcast,
        isSubscribed: Bool
    ) {
        let wasSubscribed =
            contains(podcast: podcast) || podcast.isSubscribed
        subscribedPodcasts.removeAll { $0.id == podcast.id }

        if isSubscribed {
            var summary = podcast
            summary.isSubscribed = true
            subscribedPodcasts.insert(summary, at: 0)
        }

        if wasSubscribed != isSubscribed {
            subscribedPodcastTotalCount += isSubscribed ? 1 : -1
        }
        subscribedPodcastTotalCount = max(
            subscribedPodcastTotalCount,
            subscribedPodcasts.count
        )
        subscribedPodcastsNextOffset = subscribedPodcasts.count
        hasMoreSubscribedPodcasts =
            subscribedPodcastsNextOffset < subscribedPodcastTotalCount
        persistContentInBackground()
    }

    private func restoreContent(_ snapshot: LibraryContentSnapshot) {
        profile = snapshot.profile
        accountDetail = snapshot.accountDetail
        favoriteSongs = snapshot.favoriteSongs
        favoriteSongIDs = snapshot.favoriteSongIDs
        favoriteSongIDSet = Set(snapshot.favoriteSongIDs)
        favoriteSongTotalCount = snapshot.favoriteSongTotalCount ?? snapshot.favoriteSongIDs.count
        favoriteSongsNextOffset = snapshot.favoriteSongsNextOffset
        qqFavoriteSongsHaveMore = snapshot.favoriteSongsHaveMore
            ?? (favoriteSongsNextOffset < favoriteSongTotalCount)
        favoritePlaylists = snapshot.favoritePlaylists
        favoriteAlbums = snapshot.favoriteAlbums
        favoriteArtists = snapshot.favoriteArtists
        subscribedPodcasts = snapshot.subscribedPodcasts
        subscribedPodcastTotalCount = snapshot.subscribedPodcastTotalCount
        subscribedPodcastsNextOffset = snapshot.subscribedPodcastsNextOffset
        hasMoreSubscribedPodcasts = snapshot.hasMoreSubscribedPodcasts
        recentSongs = snapshot.recentSongs
        likedPlaylistID = snapshot.likedPlaylistID
    }

    private func persistContentInBackground() {
        Task { [weak self] in await self?.persistContent() }
    }

    private func persistContent() async {
        guard let profile,
              loadedCookie == api.accountScope else {
            return
        }
        let snapshot = LibraryContentSnapshot(
            profile: profile,
            accountDetail: accountDetail,
            favoriteSongs: favoriteSongs,
            favoriteSongIDs: favoriteSongIDs,
            favoriteSongsNextOffset: favoriteSongsNextOffset,
            favoriteSongTotalCount: favoriteSongTotalCount,
            favoriteSongsHaveMore: hasMoreFavoriteSongs,
            favoritePlaylists: favoritePlaylists,
            favoriteAlbums: favoriteAlbums,
            favoriteArtists: favoriteArtists,
            subscribedPodcasts: subscribedPodcasts,
            subscribedPodcastTotalCount: subscribedPodcastTotalCount,
            subscribedPodcastsNextOffset: subscribedPodcastsNextOffset,
            hasMoreSubscribedPodcasts: hasMoreSubscribedPodcasts,
            recentSongs: recentSongs,
            likedPlaylistID: likedPlaylistID
        )
        await api.pageContentCache.store(snapshot, for: LibraryContentSnapshot.cacheKey)
    }

    private func normalizedSubscribedPodcasts(
        _ podcasts: [Podcast]
    ) -> [Podcast] {
        var identifiers = Set<Int>()
        return podcasts.compactMap { podcast in
            guard podcast.id > 0,
                  identifiers.insert(podcast.id).inserted else {
                return nil
            }
            var subscribedPodcast = podcast
            subscribedPodcast.isSubscribed = true
            return subscribedPodcast
        }
    }
}

private enum LibraryOperationError: LocalizedError {
    case playlistIsNotOwned
    case favoriteSongsIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .playlistIsNotOwned:
            L10n.string("ui.library.error.owned_playlist_only")
        case .favoriteSongsIncomplete(let message):
            message
        }
    }
}
