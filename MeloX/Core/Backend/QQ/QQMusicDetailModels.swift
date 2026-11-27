import Foundation

nonisolated struct QQPlaylistDetail: Sendable {
    let id: Int
    let dirid: Int
    let name: String
    let coverURL: String?
    let description: String?
    let trackCount: Int
    let playCount: Int
    let creatorName: String?
    let creatorID: Int
    let songs: [QQSearchSong]
    let total: Int
    let hasMore: Bool
    var nextOffset: Int? = nil
}

nonisolated struct QQAlbumDetail: Sendable {
    let album: QQSearchAlbum
    let description: String?
    let publishDate: String?
    let songs: [QQSearchSong]
}

nonisolated struct QQArtistDetail: Sendable {
    let artist: QQSearchArtist
    let description: String?
    let songs: [QQSearchSong]
    let albums: [QQSearchAlbum]
}

nonisolated struct QQToplist: Sendable {
    let id: Int
    let name: String
    let coverURL: String?
    let description: String?
    let trackCount: Int
    let playCount: Int
}
