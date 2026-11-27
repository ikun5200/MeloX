"""Offline integration checks using the production LibraryStore and queue."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "MeloX/Core/Library/LibraryStore.swift",
    "MeloX/Core/Library/FavoriteSongOrder.swift",
    "MeloX/Core/Library/FavoriteSongOrderStore.swift",
    "MeloX/Core/Library/LibrarySongBatchResult.swift",
    "MeloX/Core/Library/LibraryContentSnapshot.swift",
    "MeloX/Core/Storage/AppStorageLocations.swift",
    "MeloX/Core/Backend/QQ/QQMusicError.swift",
    "MeloX/Core/Models/Music/SongCollectionPage.swift",
    "MeloX/Features/MusicCollection/MusicCollectionSelection.swift",
    "MeloX/Core/Playback/Queue/PlaybackQueue.swift",
]
STUBS = r'''
import Foundation

nonisolated enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ values: CVarArg...) -> String { key }
}

@inline(__always)
func rigTrace(_ scope: String, _ message: @autoclosure () -> String) {}
struct Song: Codable, Equatable, Sendable { let id: Int; var name: String = "Song" }
struct Artist: Codable, Sendable { let id: Int }
struct Album: Codable, Sendable { let id: Int }
struct Podcast: Codable, Sendable { let id: Int; var isSubscribed = true }
struct PodcastPage { let podcasts: [Podcast]; let hasMore: Bool; let totalCount: Int? }
struct AccountProfile: Codable, Sendable { let id: Int; var nickname = "MeloX" }
struct AccountDetail: Codable, Sendable { let profile: AccountProfile }
struct UserSummary: Codable, Sendable { let userID: Int; let nickname: String }
struct Playlist: Codable, Sendable {
    let id: Int
    var name: String
    var coverURLString: String? = nil
    var creator: UserSummary? = nil
    var dirid: Int? = nil
    var tracks: [Song] = []
    mutating func removeSong(id: Int) { tracks.removeAll { $0.id == id } }
}
enum ContentFeature { case listeningHistory }
enum LoadingPhase: Equatable { case loaded, loading, failed(String) }
enum APIError: LocalizedError {
    case notLoggedIn, invalidResponse
    var errorDescription: String? { "fixture API error" }
}
@MainActor final class AppSettings {
    var cookie = "qq:account-a"
    func isContentFeatureEnabled(_ feature: ContentFeature) -> Bool { false }
}
@MainActor final class PageContentCache {
    let settings: AppSettings
    var data: [String: Data] = [:]
    init(settings: AppSettings) { self.settings = settings }
    func value<Value: Decodable>(for key: String) async -> Value? {
        guard let value = data[settings.cookie + "/" + key] else { return nil }
        return try? JSONDecoder().decode(Value.self, from: value)
    }
    func store<Value: Encodable>(_ value: Value, for key: String) async {
        data[settings.cookie + "/" + key] = try? JSONEncoder().encode(value)
    }
    func removeAccount(scope: String) async { data = data.filter { !$0.key.hasPrefix(scope + "/") } }
}
@MainActor final class NeteaseAPI {
    let settings: AppSettings
    let pageContentCache: PageContentCache
    var songsByAccount: [String: [Song]]
    var pageOffsets: [Int] = []
    var pageDelay = false
    var writeDelay = false
    var writeErrors: [Int: QQMusicError] = [:]
    var addErrors: Set<Int> = []
    var writes: [Int] = []
    var additions: [Int] = []
    var isUsingSourceResolver = true
    var accountScope: String { settings.cookie }
    var hasAccount: Bool { !settings.cookie.isEmpty }
    init(settings: AppSettings) {
        self.settings = settings
        pageContentCache = PageContentCache(settings: settings)
        songsByAccount = ["qq:account-a": (1...1050).map { Song(id: $0) }, "qq:account-b": [Song(id: 2001), Song(id: 2002)]]
    }
    func clearAccount() { settings.cookie = "" }
    func accountProfile() async throws -> AccountProfile { AccountProfile(id: accountScope == "qq:account-a" ? 11 : 22) }
    func userDetail(userID: Int) async throws -> AccountDetail { AccountDetail(profile: AccountProfile(id: userID)) }
    func userPlaylists(userID: Int) async throws -> [Playlist] {
        [Playlist(id: 99, name: "Fixture", creator: UserSummary(userID: userID, nickname: "MeloX"), dirid: 1)]
    }
    func subscribedAlbums() async throws -> [Album] { [] }
    func subscribedArtists() async throws -> [Artist] { [] }
    func recentSongs() async throws -> [Song] { [] }
    func sourceLikedSongsPage(offset: Int = 0, limit: Int = 100) async throws -> SongCollectionPage {
        let songs = songsByAccount[accountScope] ?? []
        pageOffsets.append(offset)
        let page = Array(songs.dropFirst(offset).prefix(limit))
        if pageDelay { try await Task.sleep(for: .milliseconds(35)) }
        return SongCollectionPage(songs: page, nextOffset: offset + page.count, totalCount: songs.count)
    }
    func likedSongIDs(userID: Int, likedPlaylistID: Int?) async throws -> [Int] { (songsByAccount[accountScope] ?? []).map(\.id) }
    func songDetailsPage(ids: [Int], offset: Int, limit: Int) async throws -> SongCollectionPage {
        SongCollectionPage(songs: Array(ids.dropFirst(offset).prefix(limit)).map { Song(id: $0) }, nextOffset: min(offset + limit, ids.count), totalCount: ids.count)
    }
    func songDetailsCollection(ids: [Int], prefetched: [Song]) async throws -> [Song] { ids.map { Song(id: $0) } }
    func setSongLiked(id: Int, isLiked: Bool) async throws {
        let scope = accountScope
        writes.append(id)
        if writeDelay { try await Task.sleep(for: .milliseconds(35)) }
        if let error = writeErrors[id] { throw error }
        if isLiked { songsByAccount[scope, default: []].insert(Song(id: id), at: 0) }
        else { songsByAccount[scope]?.removeAll { $0.id == id } }
    }
    func addSong(id: Int, toPlaylistID: Int, dirid: Int?) async throws {
        additions.append(id)
        if addErrors.contains(id) { throw QQMusicError.server(code: 500, message: nil) }
    }
    func removeSong(id: Int, fromPlaylistID: Int, dirid: Int?) async throws {}
    func setPlaylistSubscribed(id: Int, isSubscribed: Bool) async throws {}
    func setAlbumSubscribed(id: Int, isSubscribed: Bool) async throws {}
    func setArtistFollowed(id: Int, isFollowed: Bool) async throws {}
    func setPodcastSubscribed(id: Int, isSubscribed: Bool) async throws {}
    func subscribedPodcasts(offset: Int, limit: Int) async throws -> PodcastPage { PodcastPage(podcasts: [], hasMore: false, totalCount: 0) }
    func deletePlaylist(id: Int, dirid: Int?) async throws {}
    func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist { Playlist(id: 100, name: name, dirid: 2) }
}
'''
HARNESS = r'''
import Foundation

@main @MainActor struct Harness {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-editing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orderStore = FavoriteSongOrderStore(directory: directory.appendingPathComponent("orders"))
        let settings = AppSettings()
        let api = NeteaseAPI(settings: settings)
        let library = LibraryStore(api: api, settings: settings, orderStore: orderStore)
        await library.refresh(force: true)
        precondition(library.favoriteSongs.count == 1050 && library.favoriteSongTotalCount == 1050)
        precondition(!library.hasMoreFavoriteSongs && api.pageOffsets == Array(stride(from: 0, to: 1050, by: 100)))

        let reverse = Array((1...1050).reversed())
        try library.saveFavoriteSongOrder(reverse, accountScope: api.accountScope)
        precondition(library.orderedFavoriteSongs.map(\.id) == reverse)
        let playback = try await library.favoriteSongsForPlayback()
        precondition(playback.map(\.id) == reverse)
        let reopened = LibraryStore(api: api, settings: settings, orderStore: orderStore)
        await reopened.refresh(force: true)
        precondition(reopened.orderedFavoriteSongs.map(\.id) == reverse)

        let backup = directory.appendingPathComponent("backup")
        try FileManager.default.moveItem(at: orderStore.directory, to: backup)
        try Data("not a directory".utf8).write(to: orderStore.directory)
        do { try reopened.saveFavoriteSongOrder(Array(1...1050), accountScope: api.accountScope); preconditionFailure("save should fail") }
        catch { }
        precondition(reopened.orderedFavoriteSongs.map(\.id) == reverse)
        try FileManager.default.removeItem(at: orderStore.directory)
        try FileManager.default.moveItem(at: backup, to: orderStore.directory)
        let savedOrder = try orderStore.load(accountScope: api.accountScope)
        precondition(savedOrder?.songIDs == reverse)

        api.writeErrors[4] = QQMusicError.server(code: 500, message: nil)
        let originalIndex = reopened.orderedFavoriteSongs.firstIndex { $0.id == 4 }
        reopened.toggle(song: Song(id: 4))
        for _ in 0..<100 where !reopened.pendingFavoriteSongIDs.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        precondition(reopened.pendingFavoriteSongIDs.isEmpty)
        precondition(reopened.orderedFavoriteSongs.firstIndex { $0.id == 4 } == originalIndex)

        api.writes.removeAll()
        let partial = await reopened.removeFavoriteSongs([Song(id: 5), Song(id: 4), Song(id: 3)])
        precondition(partial.succeededSongIDs == [5, 3] && partial.failedSongIDs == [4])
        precondition(api.writes == [5, 4, 3] && reopened.contains(song: Song(id: 4)))
        precondition(!reopened.contains(song: Song(id: 5)) && !reopened.contains(song: Song(id: 3)))
        api.writeErrors[4] = QQMusicError.server(code: 2001, message: nil)
        api.writes.removeAll()
        let rate = await reopened.removeFavoriteSongs([Song(id: 4), Song(id: 2), Song(id: 1)])
        precondition(api.writes == [4] && rate.failedSongIDs == [4, 2, 1])
        api.writeErrors[4] = QQMusicError.credentialExpired(code: 1000)
        api.writes.removeAll()
        let auth = await reopened.removeFavoriteSongs([Song(id: 4), Song(id: 2)])
        precondition(api.writes == [4] && auth.failedSongIDs == [4, 2])
        api.addErrors = [4]
        let added = await reopened.add(songs: [Song(id: 5), Song(id: 4), Song(id: 3)], to: reopened.ownedPlaylists[0])
        precondition(added.succeededSongIDs == [5, 3] && added.failedSongIDs == [4])
        precondition(api.additions == [5, 4, 3])

        api.writeErrors.removeAll()
        api.writeDelay = true
        let pending = Task { @MainActor in await reopened.removeFavoriteSongs([Song(id: 1), Song(id: 2)]) }
        try await Task.sleep(for: .milliseconds(5))
        settings.cookie = "qq:account-b"
        reopened.clearAccountData()
        await reopened.refresh(force: true)
        _ = await pending.value
        precondition(reopened.favoriteSongs.map(\.id) == [2001, 2002])
        precondition(!reopened.isUpdatingFavoriteSongs)
        try reopened.saveFavoriteSongOrder([2002, 2001], accountScope: api.accountScope)
        let accountAOrder = try orderStore.load(accountScope: "qq:account-a")
        precondition(accountAOrder?.songIDs != [2002, 2001])

        api.pageDelay = true
        settings.cookie = "qq:account-a"
        reopened.clearAccountData()
        let stale = Task { @MainActor in await reopened.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(5))
        settings.cookie = "qq:account-b"
        reopened.clearAccountData()
        await reopened.refresh(force: true)
        await stale.value
        precondition(reopened.favoriteSongs.map(\.id) == [2001, 2002])
        precondition(reopened.orderedFavoriteSongs.map(\.id) == [2002, 2001])

        var selection = MusicCollectionSelection()
        selection.beginSelection()
        selection.toggleAll(songIDs: [1, 2, 3])
        selection.toggleAll(songIDs: [2, 3])
        precondition(selection.selectedSongIDs == [1])
        selection.toggleSelection(songID: 4)
        precondition(selection.orderedIDs(in: [4, 3, 2, 1]) == [4, 1])
        selection.retainSelection(in: [4])
        precondition(selection.selectedSongIDs == [4])

        var queue = PlaybackQueue()
        queue.replace(with: [Song(id: 1), Song(id: 2), Song(id: 3)], startingAt: 0)
        queue.insertNext(contentsOf: [Song(id: 10), Song(id: 11), Song(id: 12)])
        precondition(queue.songs.map(\.id) == [1, 10, 11, 12, 2, 3])
        queue.replace(with: [Song(id: 1), Song(id: 2), Song(id: 3)], startingAt: 0)
        queue.toggleShuffle()
        queue.insertNext(contentsOf: [Song(id: 20), Song(id: 21)])
        precondition(queue.upcomingIndices(wraps: false).prefix(2).map { queue.songs[$0].id } == [20, 21])

        let snapshot = LibraryContentSnapshot(profile: AccountProfile(id: 11), accountDetail: nil, favoriteSongs: [Song(id: 1)], favoriteSongIDs: [1], favoriteSongsNextOffset: 1, favoritePlaylists: [], favoriteAlbums: [], favoriteArtists: [], subscribedPodcasts: [], subscribedPodcastTotalCount: 0, subscribedPodcastsNextOffset: 0, hasMoreSubscribedPodcasts: false, recentSongs: [], likedPlaylistID: nil)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        old.removeValue(forKey: "favoriteSongTotalCount")
        old.removeValue(forKey: "favoriteSongsHaveMore")
        let decoded = try JSONDecoder().decode(LibraryContentSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(decoded.favoriteSongTotalCount == nil && decoded.favoriteSongsHaveMore == nil)
        print("Production LibraryStore pagination, persistent order, IO failure, batch results, account guards, selection, queue order, and legacy cache checks passed")
    }
}
'''


class LibraryEditingChecks(unittest.TestCase):
    def test_library_editing(self):
        with tempfile.TemporaryDirectory(prefix="melox-library-editing-") as directory:
            directory = Path(directory)
            stub = directory / "Stubs.swift"
            main = directory / "Harness.swift"
            executable = directory / "checks"
            stub.write_text(STUBS)
            main.write_text(HARNESS)
            subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *[str(ROOT / p) for p in SOURCES], str(stub), str(main), "-o", str(executable)], check=True, cwd=ROOT)
            subprocess.run([str(executable)], check=True, cwd=ROOT, timeout=60)


if __name__ == "__main__":
    unittest.main()
