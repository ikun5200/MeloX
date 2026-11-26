import Foundation

nonisolated enum QQSearchKind: Int, Sendable {
    case songs = 0
    case artists = 1
    case albums = 2
    case playlists = 3
}

nonisolated struct QQSearchArtist: Sendable {
    let id: Int
    let mid: String
    let name: String
    let avatarURL: String?
    let isFollowed: Bool
}

nonisolated struct QQSearchSong: Sendable {
    let id: Int
    let mid: String
    let mediaMID: String?
    let name: String
    let artists: [QQSearchArtist]
    let albumID: Int
    let albumMID: String
    let albumName: String
    let coverURL: String?
    let durationSeconds: Int
    let musicVideoID: Int?
    let musicVideoMID: String?
    var audioAvailability: SongAudioAvailability = .unknown
}

nonisolated struct QQSearchAlbum: Sendable {
    let id: Int
    let mid: String
    let name: String
    let coverURL: String?
    let artists: [QQSearchArtist]
    let publishDate: String?
}

nonisolated struct QQSearchPlaylist: Sendable {
    let id: Int
    let dirid: Int
    let name: String
    let coverURL: String?
    let trackCount: Int
    let playCount: Int
    let creatorName: String?
}

nonisolated struct QQSearchResult: Sendable {
    var songs: [QQSearchSong] = []
    var artists: [QQSearchArtist] = []
    var albums: [QQSearchAlbum] = []
    var playlists: [QQSearchPlaylist] = []
}

nonisolated enum QQMusicSearchParser {
    static func songs(_ items: [[String: Any]]) -> [QQSearchSong] {
        items.compactMap(song)
    }

    static func artists(_ items: [[String: Any]]) -> [QQSearchArtist] {
        items.compactMap(artist)
    }

    static func albums(_ items: [[String: Any]]) -> [QQSearchAlbum] {
        items.compactMap(album)
    }

    static func playlists(_ items: [[String: Any]]) -> [QQSearchPlaylist] {
        items.compactMap(playlist)
    }

    static func song(_ item: [String: Any]) -> QQSearchSong? {
        let mid = string(item, "songmid", "mid", "songMid") ?? ""
        let id = int(item, "songid", "id", "songId", "songID")
            ?? stableID(mid)
        guard id > 0, !mid.isEmpty else { return nil }

        let albumDictionary = dictionary(item["album"])
        let albumID = int(item, "albumid", "albumID", "albumId")
            ?? int(albumDictionary, "id", "albumID", "albumId")
            ?? 0
        let albumMID = string(item, "albummid", "albumMid", "albumMID")
            ?? string(albumDictionary, "mid", "albumMid", "albumMID")
            ?? ""
        let albumName = string(item, "albumname", "albumName")
            ?? string(albumDictionary, "name", "title")
            ?? ""

        let artistValues = (item["singer"] as? [Any])
            ?? (item["singers"] as? [Any])
            ?? []
        var artists = artistValues.compactMap { value -> QQSearchArtist? in
            if let dictionary = value as? [String: Any] {
                return artist(dictionary)
            }
            if let name = value as? String, !name.isEmpty {
                return QQSearchArtist(
                    id: 0,
                    mid: "",
                    name: name,
                    avatarURL: nil,
                    isFollowed: false
                )
            }
            return nil
        }
        if artists.isEmpty,
           let singerName = string(item, "singername", "singerName"),
           !singerName.isEmpty {
            artists = [
                QQSearchArtist(
                    id: 0,
                    mid: "",
                    name: singerName,
                    avatarURL: nil,
                    isFollowed: false
                ),
            ]
        }

        let fileDictionary = dictionary(item["file"])
        let mediaMID = string(item, "media_mid", "strMediaMid", "mediaMid")
            ?? string(fileDictionary, "media_mid", "mediaMid")

        let mvDictionary = dictionary(item["mv"])
        let musicVideoID = int(item, "mvid", "mvId")
            ?? int(mvDictionary, "id", "mvid")
        let musicVideoMID = string(item, "vid", "mvVid")
            ?? string(mvDictionary, "vid")

        let coverURL = string(albumDictionary, "pic", "picUrl", "cover")
            ?? albumCoverURL(mid: albumMID)

        return QQSearchSong(
            id: id,
            mid: mid,
            mediaMID: mediaMID,
            name: plain(
                string(item, "songname", "name", "title") ?? ""
            ),
            artists: artists,
            albumID: albumID,
            albumMID: albumMID,
            albumName: albumName,
            coverURL: coverURL,
            durationSeconds: int(item, "interval", "duration") ?? 0,
            musicVideoID: musicVideoID,
            musicVideoMID: musicVideoMID,
            audioAvailability: audioAvailability(from: fileDictionary)
        )
    }

    /// `file` 给出这首歌每种编码的字节数，0 表示没有这一档。
    /// `size_new` 的下标含义：0 臻品母带、1 臻品音质 2.0、2 臻品全景声 5.1。
    static func audioAvailability(
        from file: [String: Any]?
    ) -> SongAudioAvailability {
        guard let file,
              file["size_128mp3"] != nil || file["size_flac"] != nil else {
            return .unknown
        }
        let extended = (file["size_new"] as? [Any] ?? []).map {
            ($0 as? NSNumber)?.int64Value ?? 0
        }
        func size(_ key: String) -> Int64 {
            (file[key] as? NSNumber)?.int64Value ?? 0
        }
        func extendedSize(_ index: Int) -> Int64 {
            extended.indices.contains(index) ? extended[index] : 0
        }
        return SongAudioAvailability(
            encodingSizes: [
                .standard: size("size_128mp3"),
                .high: size("size_320mp3"),
                .lossless: size("size_flac"),
                .hiResolution: size("size_hires"),
                .highDefinitionSurround: extendedSize(1),
                .immersiveSurround: extendedSize(2),
                .ultraClearMaster: extendedSize(0),
            ]
        )
    }

    static func artist(_ item: [String: Any]) -> QQSearchArtist? {
        let mid = string(item, "singerMID", "mid", "singerMid") ?? ""
        let name = plain(
            string(item, "singerName", "name", "title") ?? ""
        )
        guard !name.isEmpty else { return nil }
        // An album's singer list can name an artist with no account behind
        // it: QQ leaves the id at 0 and the mid empty.
        let stored = int(item, "singerID", "id", "singerId", "singer_id") ?? 0
        let id = stored > 0
            ? stored
            : (mid.isEmpty ? stableID(name) : stableID(mid))
        guard id > 0 else { return nil }
        let avatar = string(item, "singerPic", "pic", "picUrl")
            ?? singerCoverURL(mid: mid)
        return QQSearchArtist(
            id: id,
            mid: mid,
            name: name,
            avatarURL: avatar,
            isFollowed: bool(item, "isFollow", "followed") ?? false
        )
    }

    static func album(_ item: [String: Any]) -> QQSearchAlbum? {
        let mid = string(item, "albumMid", "albumMID", "mid", "albummid") ?? ""
        let id = int(item, "albumID", "albumId", "id", "albumid")
            ?? stableID(mid)
        guard id > 0 || !mid.isEmpty else { return nil }
        let name = plain(
            string(item, "albumName", "name", "title", "albumname") ?? ""
        )
        guard !name.isEmpty else { return nil }

        return QQSearchAlbum(
            id: id,
            mid: mid,
            name: name,
            coverURL: string(item, "pic", "picUrl", "logo")
                ?? albumCoverURL(mid: mid),
            artists: artists(of: item),
            publishDate: string(item, "publish_date", "time_public", "pubtime")
        )
    }

    /// An album's artists. The same list arrives as `singer` (an array, or
    /// one name as text), `singer_list` or `singers`, depending on the
    /// endpoint and on how complete QQ's record is; the first that names
    /// anyone wins.
    private static func artists(of item: [String: Any]) -> [QQSearchArtist] {
        for key in ["singer", "singer_list", "singers"] {
            guard let value = item[key], !(value is NSNull) else { continue }
            var names: [String] = []
            if let list = value as? [Any] {
                names = list.compactMap { element in
                    if let dictionary = element as? [String: Any] {
                        return artist(dictionary)?.name
                    }
                    return (element as? String).map(plain)
                }
            } else if let text = value as? String {
                // Tags come off first: QQ marks the matched words with
                // `<em>`, and a closing tag holds a slash.
                names = plain(text)
                    .split(whereSeparator: { $0 == "/" || $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let artists = names.filter { !$0.isEmpty }.map { name in
                QQSearchArtist(
                    id: stableID(name),
                    mid: "",
                    name: name,
                    avatarURL: nil,
                    isFollowed: false
                )
            }
            if !artists.isEmpty { return artists }
        }
        return []
    }

    static func playlist(_ item: [String: Any]) -> QQSearchPlaylist? {
        let id = int(item, "dissid", "id", "tid") ?? 0
        let name = plain(
            string(item, "dissname", "name", "title") ?? ""
        )
        guard id > 0, !name.isEmpty else { return nil }
        return QQSearchPlaylist(
            id: id,
            dirid: int(item, "dirid", "dirId") ?? 0,
            name: name,
            coverURL: string(item, "logo", "picurl", "cover"),
            trackCount: int(item, "songnum", "songNum", "song_cnt") ?? 0,
            playCount: int(item, "listennum", "playCount", "play_cnt") ?? 0,
            creatorName: plain(
                string(item, "nickname")
                    ?? string(dictionary(item["creator"]), "name", "nickname")
                    ?? ""
            )
        )
    }

    static func albumCoverURL(mid: String, size: Int = 300) -> String? {
        guard !mid.isEmpty else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T002R\(size)x\(size)M000\(mid).jpg"
    }

    /// 搜索接口会在命中词两侧插入 `<em>` 高亮标签，展示前统一去掉。
    private static func plain(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func singerCoverURL(mid: String, size: Int = 300) -> String? {
        guard !mid.isEmpty else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T001R\(size)x\(size)M000\(mid).jpg"
    }

    /// QQ 的稳定标识有时候只给了 mid。用 FNV-1a 生成跨进程稳定的本地 Int。
    static func stableID(_ value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash & 0x7FFF_FFFF)
    }

    /// 评论 ID 是带 `!` 与 `*` 的字符串，用 63 位稳定哈希映射到 Int64。
    static func stableID64(_ value: String) -> Int64 {
        guard !value.isEmpty else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int64(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func firstValue(
        _ dictionary: [String: Any]?,
        _ keys: [String]
    ) -> Any? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key], !(value is NSNull) {
                return value
            }
        }
        return nil
    }

    private static func int(_ dictionary: [String: Any]?, _ keys: String...) -> Int? {
        guard let value = firstValue(dictionary, keys) else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func string(
        _ dictionary: [String: Any]?,
        _ keys: String...
    ) -> String? {
        guard let value = firstValue(dictionary, keys) else { return nil }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func bool(_ dictionary: [String: Any]?, _ keys: String...) -> Bool? {
        guard let value = firstValue(dictionary, keys) else { return nil }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }
}
