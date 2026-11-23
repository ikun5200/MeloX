import Foundation

nonisolated struct QQMVDetail: Sendable {
    let vid: String
    let name: String
    let coverURL: String?
    let description: String?
    let duration: Int
    let playCount: Int
    let artists: [QQSearchArtist]
    let publishDate: Int
}

nonisolated struct QQMVPlayback: Sendable {
    let mp4URLs: [URL]
    let hlsURL: URL?

    var preferredURL: URL? {
        mp4URLs.first ?? hlsURL
    }
}
