import Foundation

/// QQ 音乐 CGI 客户端（第一版只覆盖搜索与搜索联想）。
///
/// 读取类接口使用匿名 Android 会话：先调用 `music.getSession.session/GetSession`
/// 获取 uid/sid，再带 36 位 QIMEI 调用搜索。歌曲搜索走公开的
/// `client_search_cp`，不需要会话；歌手/专辑/歌单搜索走移动端 CGI。
nonisolated struct QQMusicClient: @unchecked Sendable {
    private let urlSession: URLSession
    private let guid: String
    private let qimei36: String
    private let credential: QQCredential?

    private static let cgiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    private static let userAgent = "QQMusic 20090008(android 15)"

    init(
        session: URLSession = .shared,
        credential: QQCredential? = nil,
        guid: String = QQMusicClient.makeGUID(),
        qimei36: String = QQMusicClient.makeQIMEI36()
    ) {
        self.urlSession = session
        self.credential = credential
        self.guid = guid
        self.qimei36 = qimei36
    }

    func replacingCredential(_ credential: QQCredential?) -> QQMusicClient {
        QQMusicClient(
            session: urlSession,
            credential: credential,
            guid: guid,
            qimei36: qimei36
        )
    }

    func search(
        query: String,
        kind: QQSearchKind,
        limit: Int = 30,
        page: Int = 1
    ) async throws -> QQSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return QQSearchResult() }

        switch kind {
        case .songs:
            let songs = try await searchSongs(
                query: trimmed,
                limit: limit,
                page: page
            )
            return QQSearchResult(songs: songs)

        case .artists:
            let items = try await mobileSearchItems(
                query: trimmed,
                kind: kind,
                limit: limit,
                page: page
            )
            var artists = QQMusicSearchParser.artists(items)
            if artists.isEmpty {
                artists = await smartBoxArtists(trimmed)
            }
            return QQSearchResult(artists: artists)

        case .albums:
            let items = try await mobileSearchItems(
                query: trimmed,
                kind: kind,
                limit: limit,
                page: page
            )
            var albums = QQMusicSearchParser.albums(items)
            if albums.isEmpty {
                albums = await smartBoxAlbums(trimmed)
            }
            return QQSearchResult(albums: albums)

        case .playlists:
            let items = try await mobileSearchItems(
                query: trimmed,
                kind: kind,
                limit: limit,
                page: page
            )
            return QQSearchResult(
                playlists: QQMusicSearchParser.playlists(items)
            )
        }
    }

    func searchSuggestions(_ query: String) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = try await smartBoxData(trimmed)
        var seen = Set<String>()
        var suggestions: [String] = []

        for key in ["song", "singer", "album"] {
            guard let section = data[key] as? [String: Any],
                  let items = section["itemlist"] as? [[String: Any]] else {
                continue
            }
            for item in items {
                guard let name = item["name"] as? String else { continue }
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, seen.insert(value).inserted else { continue }
                suggestions.append(value)
            }
        }

        return Array(suggestions.prefix(8))
    }

    // MARK: - Detail endpoints

    func playlistDetail(
        id: Int,
        dirid: Int = 0,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> QQPlaylistDetail {
        var anonymous: (uid: String, sid: String)?
        if credential?.isValid != true {
            anonymous = try await anonymousSession()
        }
        return try await fetchPlaylistDetail(
            id: id,
            dirid: dirid,
            limit: limit,
            offset: offset,
            session: anonymous
        )
    }

    private func fetchPlaylistDetail(
        id: Int,
        dirid: Int,
        limit: Int,
        offset: Int,
        session: (uid: String, sid: String)?
    ) async throws -> QQPlaylistDetail {
        var parameter: [String: Any] = [
            "disstid": id,
            "dirid": dirid,
            "tag": true,
            "song_begin": offset,
            "song_num": limit,
            "userinfo": true,
            "orderlist": true,
            "onlysonglist": false,
        ]
        if dirid == Self.likedSongsDirid,
           let encryptedUIN = credential?.encryptUIN,
           !encryptedUIN.isEmpty {
            parameter["enc_host_uin"] = encryptedUIN
        }
        let data = try await cgiCall(
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            parameter: parameter,
            session: session
        )

        let info = Self.dictionary(data["dirinfo"]) ?? [:]
        let creator = Self.dictionary(info["creator"]) ?? [:]
        let songItems = Self.dictionaryArray(data["songlist"])
        let songs = QQMusicSearchParser.songs(songItems)
        let nextOffset = offset + songItems.count
        let total = Self.int(data["total_song_num"])
            ?? Self.int(info["songnum"])
            ?? nextOffset

        return QQPlaylistDetail(
            id: Self.int(info["id"]) ?? id,
            dirid: Self.int(info["dirid"]) ?? 0,
            name: Self.string(info["title"])
                ?? Self.string(info["dissname"])
                ?? "",
            coverURL: Self.string(info["picurl"])
                ?? Self.string(info["cover"]),
            description: Self.string(info["desc"]),
            trackCount: Self.int(info["songnum"]) ?? total,
            playCount: Self.int(info["listennum"]) ?? 0,
            creatorName: Self.string(creator["nick"])
                ?? Self.string(info["nick"]),
            creatorID: Self.int(creator["musicid"])
                ?? Self.int(info["host_uin"])
                ?? 0,
            songs: songs,
            total: total,
            hasMore: (Self.int(data["hasmore"]) ?? 0) == 1
                || total > nextOffset,
            nextOffset: nextOffset
        )
    }

    func albumDetail(
        id: Int,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> QQAlbumDetail {
        let session = try await anonymousSession()
        let detail = try await cgiCall(
            module: "music.musichallAlbum.AlbumInfoServer",
            method: "GetAlbumDetail",
            parameter: ["albumId": id],
            session: session
        )
        let basic = Self.dictionary(detail["basicInfo"]) ?? [:]
        let singerContainer = Self.dictionary(detail["singer"]) ?? [:]
        let singers = Self.dictionaryArray(singerContainer["singerList"])

        var artists = QQMusicSearchParser.artists(singers)
        if artists.isEmpty,
           let singer = QQMusicSearchParser.artist(basic) {
            artists = [singer]
        }
        let album = QQMusicSearchParser.album(basic) ?? QQSearchAlbum(
            id: id,
            mid: Self.string(basic["albumMid"]) ?? "",
            name: Self.string(basic["albumName"]) ?? "",
            coverURL: nil,
            artists: artists,
            publishDate: Self.string(basic["publishDate"])
        )
        let resolvedAlbum = QQSearchAlbum(
            id: album.id,
            mid: album.mid,
            name: album.name,
            coverURL: album.coverURL,
            artists: album.artists.isEmpty ? artists : album.artists,
            publishDate: album.publishDate
                ?? Self.string(basic["publishDate"])
        )

        let songsData = try await cgiCall(
            module: "music.musichallAlbum.AlbumSongList",
            method: "GetAlbumSongList",
            parameter: [
                "albumId": id,
                "begin": offset,
                "num": limit,
            ],
            session: session
        )
        let songInfos = Self.dictionaryArray(songsData["songList"])
            .compactMap { Self.dictionary($0["songInfo"]) }

        return QQAlbumDetail(
            album: resolvedAlbum,
            description: Self.string(basic["desc"]),
            publishDate: Self.string(basic["publishDate"]),
            songs: QQMusicSearchParser.songs(songInfos)
        )
    }

    func artistDetail(
        mid: String,
        songLimit: Int = 100,
        albumLimit: Int = 100
    ) async throws -> QQArtistDetail {
        var anonymous: (uid: String, sid: String)?
        if credential?.isValid != true {
            anonymous = try await anonymousSession()
        }
        let session = anonymous
        let infoData = try await cgiCall(
            module: "music.UnifiedHomepage.UnifiedHomepageSrv",
            method: "GetHomepageHeader",
            parameter: ["SingerMid": mid],
            session: session
        )
        let info = Self.dictionary(infoData["Info"]) ?? [:]
        let baseInfo = Self.dictionary(info["BaseInfo"]) ?? [:]
        let singer = Self.dictionary(info["Singer"]) ?? baseInfo

        // `Info.Singer.SingerPic` is often empty in the homepage response;
        // the square avatar lives in `Info.BaseInfo.Avatar` / `BigAvatar`.
        let avatarURL = Self.string(baseInfo["Avatar"])
            ?? Self.string(baseInfo["BigAvatar"])
            ?? Self.string(singer["SingerPic"])
            ?? Self.string(singer["Avatar"])
            ?? QQMusicSearchParser.singerCoverURL(
                mid: Self.string(singer["SingerMid"]) ?? mid
            )

        let artist = QQSearchArtist(
            id: Self.int(singer["SingerID"])
                ?? Self.int(baseInfo["SingerID"])
                ?? 0,
            mid: Self.string(singer["SingerMid"]) ?? mid,
            name: Self.string(singer["Name"])
                ?? Self.string(baseInfo["Name"])
                ?? "",
            avatarURL: avatarURL,
            isFollowed: false
        )

        let songsData = try await cgiCall(
            module: "musichall.song_list_server",
            method: "GetSingerSongList",
            parameter: [
                "singerMid": mid,
                "order": 1,
                "number": songLimit,
                "begin": 0,
            ],
            session: session
        )
        let songInfos = Self.dictionaryArray(songsData["songList"])
            .compactMap { Self.dictionary($0["songInfo"]) }

        let albumsData = try await cgiCall(
            module: "music.musichallAlbum.AlbumListServer",
            method: "GetAlbumList",
            parameter: [
                "singerMid": mid,
                "order": 1,
                "number": albumLimit,
                "begin": 0,
            ],
            session: session
        )
        let albums = QQMusicSearchParser.albums(
            Self.dictionaryArray(albumsData["albumList"])
        )

        let description = await artistDescription(
            mid: mid,
            session: session
        )

        return QQArtistDetail(
            artist: QQSearchArtist(
                id: artist.id,
                mid: artist.mid.isEmpty ? mid : artist.mid,
                name: artist.name,
                avatarURL: artist.avatarURL,
                isFollowed: artist.isFollowed
            ),
            description: description,
            songs: QQMusicSearchParser.songs(songInfos),
            albums: albums
        )
    }

    func similarArtists(
        mid: String,
        limit: Int = 10
    ) async throws -> [QQSearchArtist] {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.SimilarSingerSvr",
            method: "GetSimilarSingerList",
            parameter: [
                "singerMid": mid,
                "number": min(max(limit, 1), 30),
            ],
            session: session
        )
        return QQMusicSearchParser.artists(
            Self.dictionaryArray(data["singerlist"])
        )
    }

    func newAlbums(
        area: Int,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> [QQSearchAlbum] {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "newalbum.NewAlbumServer",
            method: "get_new_album_info",
            parameter: [
                "area": area,
                "num": limit,
                "start": offset,
            ],
            session: session
        )
        return QQMusicSearchParser.albums(
            Self.dictionaryArray(data["albums"])
        )
    }

    func recommendedPlaylists(
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> [QQSearchPlaylist] {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.playlist.PlaylistSquare",
            method: "GetRecommendFeed",
            parameter: ["From": offset, "Size": limit],
            session: session
        )

        return Self.dictionaryArray(data["List"]).compactMap { item in
            guard let playlist = Self.dictionary(item["Playlist"]),
                  let basic = Self.dictionary(playlist["basic"]) else {
                return nil
            }
            let cover = Self.dictionary(basic["cover"])
            let creator = Self.dictionary(basic["creator"])
            let id = Self.int(basic["tid"])
                ?? Self.int(basic["id"])
                ?? 0
            let name = Self.string(basic["title"])
                ?? Self.string(basic["name"])
                ?? ""
            guard id > 0, !name.isEmpty else { return nil }
            return QQSearchPlaylist(
                id: id,
                dirid: Self.int(basic["dirid"]) ?? 0,
                name: name,
                coverURL: Self.string(cover?["small_url"])
                    ?? Self.string(cover?["medium_url"]),
                trackCount: Self.int(basic["song_cnt"])
                    ?? Self.int(basic["songnum"])
                    ?? 0,
                playCount: Self.int(basic["listennum"]) ?? 0,
                creatorName: Self.string(creator?["nick"])
            )
        }
    }

    func toplistDetail(
        topID: Int,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> QQPlaylistDetail {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.musicToplist.Toplist",
            method: "GetDetail",
            parameter: [
                "topId": topID,
                "offset": offset,
                "num": limit,
                "withTags": true,
            ],
            session: session
        )
        let info = Self.dictionary(data["data"]) ?? [:]
        let songs = QQMusicSearchParser.songs(
            Self.dictionaryArray(data["songInfoList"])
        )
        let total = Self.int(info["totalNum"]) ?? songs.count
        return QQPlaylistDetail(
            id: topID,
            dirid: 0,
            name: Self.string(info["title"]) ?? "",
            coverURL: Self.string(info["frontPicUrl"])
                ?? Self.string(info["headPicUrl"]),
            description: Self.string(info["intro"]),
            trackCount: total,
            playCount: Self.int(info["listenNum"]) ?? 0,
            creatorName: nil,
            creatorID: 0,
            songs: songs,
            total: total,
            hasMore: total > offset + songs.count
        )
    }

    func toplists() async throws -> [QQToplist] {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.musicToplist.Toplist",
            method: "GetAll",
            parameter: [:],
            session: session
        )

        var result: [QQToplist] = []
        for group in Self.dictionaryArray(data["group"]) {
            for item in Self.dictionaryArray(group["toplist"]) {
                let id = Self.int(item["topId"]) ?? 0
                let name = Self.string(item["title"]) ?? ""
                guard id > 0, !name.isEmpty else { continue }
                result.append(
                    QQToplist(
                        id: id,
                        name: name,
                        coverURL: Self.string(item["frontPicUrl"])
                            ?? Self.string(item["headPicUrl"]),
                        description: Self.string(item["intro"]),
                        trackCount: Self.int(item["totalNum"]) ?? 0,
                        playCount: Self.int(item["listenNum"]) ?? 0
                    )
                )
            }
        }
        return result
    }

    // MARK: - Song details

    func songDetail(mid: String) async throws -> QQSearchSong? {
        let trimmed = mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = try await cgiCall(
            module: "music.pf_song_detail_svr",
            method: "get_song_detail_yqq",
            parameter: ["song_mid": trimmed]
        )
        guard let track = Self.dictionary(data["track_info"]) else {
            return nil
        }
        return QQMusicSearchParser.song(track)
    }

    func songDetails(ids: [Int]) async throws -> [QQSearchSong] {
        guard !ids.isEmpty else { return [] }
        var songs: [QQSearchSong] = []
        let batchSize = 10
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let chunk = Array(
                ids[start..<min(start + batchSize, ids.count)]
            )
            var payload: [String: Any] = [
                "comm": buildComm(session: nil),
            ]
            for (index, id) in chunk.enumerated() {
                payload["req_\(index)"] = [
                    "module": "music.pf_song_detail_svr",
                    "method": "get_song_detail_yqq",
                    "param": ["song_id": id],
                ]
            }
            let json = try await postJSON(payload)
            for index in chunk.indices {
                guard let request = json["req_\(index)"] as? [String: Any],
                      (request["code"] as? Int ?? -1) == 0,
                      let data = request["data"] as? [String: Any],
                      let track = data["track_info"] as? [String: Any],
                      let song = QQMusicSearchParser.song(track) else {
                    continue
                }
                songs.append(song)
            }
        }
        return songs
    }

    // MARK: - MV

    func mvDetail(vid: String) async throws -> QQMVDetail? {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "video.VideoDataServer",
            method: "get_video_info_batch",
            parameter: [
                "vidlist": [vid],
                "required": [
                    "vid", "type", "sid", "cover_pic", "duration",
                    "singers", "video_switch", "msg", "name", "desc",
                    "playcnt", "pubdate", "isfav", "gmid",
                    "uploader_headurl", "uploader_nick",
                    "uploader_encuin", "uploader_uin",
                    "uploader_hasfollow", "uploader_follower_num",
                    "related_songs",
                ],
            ],
            session: session
        )
        let item = Self.dictionary(data[vid])
            ?? Self.dictionaryArray(data["vidlist"]).first
            ?? [:]
        guard !item.isEmpty else { return nil }
        let singers = Self.dictionaryArray(item["singers"])
        return QQMVDetail(
            vid: Self.string(item["vid"]) ?? vid,
            name: Self.string(item["name"]) ?? "",
            coverURL: Self.string(item["cover_pic"]),
            description: Self.string(item["desc"]),
            duration: Self.int(item["duration"]) ?? 0,
            playCount: Self.int(item["playcnt"]) ?? 0,
            artists: QQMusicSearchParser.artists(singers),
            publishDate: Self.int(item["pubdate"]) ?? 0
        )
    }

    func mvPlayback(vid: String) async throws -> QQMVPlayback {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.stream.MvUrlProxy",
            method: "GetMvUrls",
            parameter: [
                "vids": [vid],
                "request_type": 10_003,
                "guid": guid,
                "videoformat": 1,
                "format": 265,
                "dolby": 1,
                "use_new_domain": 1,
                "use_ipv6": 1,
            ],
            session: session
        )
        let entry = Self.dictionary(data[vid]) ?? [:]
        var mp4URLs: [URL] = []
        for item in Self.dictionaryArray(entry["mp4"]) {
            for value in Self.urlStrings(item) {
                guard let url = URL(string: value),
                      url.path != "/",
                      !url.path.isEmpty else {
                    continue
                }
                mp4URLs.append(url)
            }
        }
        mp4URLs.sort {
            $0.scheme == "https" && $1.scheme != "https"
        }
        var hlsURL: URL?
        for item in Self.dictionaryArray(entry["hls"]) {
            if let value = Self.string(item["m3u8"]),
               let url = URL(string: value) {
                hlsURL = url
                break
            }
            if let value = Self.urlStrings(item).first,
               let url = URL(string: value),
               url.path != "/",
               !url.path.isEmpty {
                hlsURL = url
                break
            }
        }
        return QQMVPlayback(mp4URLs: mp4URLs, hlsURL: hlsURL)
    }

    private static func urlStrings(_ item: [String: Any]) -> [String] {
        var values: [String] = []
        for key in ["freeflow_url", "comm_url", "url"] {
            guard let list = item[key] as? [String] else { continue }
            values.append(contentsOf: list.filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.hasSuffix("//")
            })
        }
        return values
    }

    // MARK: - Comments

    func songComments(
        songID: Int,
        offset: Int = 0,
        limit: Int = 20
    ) async throws -> QQCommentPage {
        let session = try await anonymousSession()
        let pageSize = min(max(limit, 1), 50)
        let data = try await cgiCall(
            module: "music.globalComment.CommentRead",
            method: "GetNewCommentList",
            parameter: [
                "PageSize": pageSize,
                "PageNum": max(offset, 0) / pageSize,
                "HashTagID": "",
                "BizType": 1,
                "PicEnable": 1,
                "LastCommentSeqNo": "",
                "SelfSeeEnable": 1,
                "BizId": String(songID),
                "AudioEnable": 1,
                "BizSubType": 2,
            ],
            session: session
        )
        let list = Self.dictionary(data["CommentList"]) ?? [:]
        let comments = Self.comments(
            Self.dictionaryArray(list["Comments"])
        )
        let total = Self.int(list["Total"]) ?? comments.count
        let hasMore = (Self.int(list["HasMore"]) ?? 0) == 1
        return QQCommentPage(
            comments: comments,
            total: total,
            hasMore: hasMore,
            nextOffset: offset + comments.count
        )
    }

    func songHotComments(
        songID: Int,
        limit: Int = 10
    ) async throws -> [QQComment] {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.globalComment.CommentRead",
            method: "GetHotCommentList",
            parameter: [
                "BizType": 1,
                "BizId": String(songID),
                "LastCommentSeqNo": "",
                "PageSize": min(max(limit, 1), 50),
                "PageNum": 0,
                "HotType": 1,
                "WithAirborne": 0,
                "PicEnable": 1,
                "BizSubType": 2,
            ],
            session: session
        )
        let list = Self.dictionary(data["CommentList"]) ?? [:]
        return Self.comments(
            Self.dictionaryArray(list["Comments"])
        )
    }

    private static func comments(
        _ items: [[String: Any]]
    ) -> [QQComment] {
        items.compactMap { item in
            guard let idText = string(item["CmId"]) else {
                return nil
            }
            let id = Int64(idText)
                ?? QQMusicSearchParser.stableID64(idText)
            let content = string(item["Content"]) ?? ""
            guard !content.isEmpty else { return nil }
            return QQComment(
                id: id,
                nickname: string(item["Nick"]) ?? "",
                avatarURL: string(item["Avatar"]),
                content: content,
                publishedAt: int(item["PubTime"]) ?? 0,
                likedCount: int(item["PraiseNum"]) ?? 0,
                isLiked: (int(item["IsPraised"]) ?? 0) == 1,
                replyCount: int(item["ReplyCnt"]) ?? 0
            )
        }
    }

    func loginUserInfo() async throws -> (
        nickname: String?,
        avatarURL: String?
    ) {
        _ = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.UserInfo.userInfoServer",
            method: "GetLoginUserInfo",
            parameter: [:]
        )
        return (
            Self.string(data["nick"])
                ?? Self.string(data["nickname"])
                ?? Self.string(data["name"]),
            Self.string(data["headurl"])
                ?? Self.string(data["headUrl"])
                ?? Self.string(data["avatar"])
        )
    }

    // MARK: - Account library

    private static let likedSongsDirid = 201

    func likedSongs(
        limit: Int = 500,
        offset: Int = 0
    ) async throws -> QQPlaylistDetail {
        _ = try requireCredential()
        return try await fetchPlaylistDetail(
            id: 0,
            dirid: Self.likedSongsDirid,
            limit: limit,
            offset: offset,
            session: nil
        )
    }

    func createdPlaylists() async throws -> [QQSearchPlaylist] {
        let credential = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistBaseRead",
            method: "GetPlaylistByUin",
            parameter: ["uin": String(credential.musicID)]
        )
        return Self.dictionaryArray(data["v_playlist"])
            .compactMap { Self.userPlaylist($0) }
    }

    func favoritePlaylists(limit: Int = 200) async throws -> [QQSearchPlaylist] {
        let credential = try requireCredential()
        guard !credential.encryptUIN.isEmpty else { return [] }
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistFavRead",
            method: "CgiGetPlaylistFavInfo",
            parameter: [
                "uin": credential.encryptUIN,
                "offset": 0,
                "size": limit,
            ]
        )
        return Self.dictionaryArray(data["v_list"]).compactMap {
            Self.userPlaylist($0, creatorKeys: ["nickname", "nick"])
        }
    }

    func favoriteAlbums(limit: Int = 200) async throws -> [QQSearchAlbum] {
        let credential = try requireCredential()
        guard !credential.encryptUIN.isEmpty else { return [] }
        let data = try await authenticatedCall(
            module: "music.musicasset.AlbumFavRead",
            method: "CgiGetAlbumFavInfo",
            parameter: [
                "euin": credential.encryptUIN,
                "offset": 0,
                "size": limit,
            ]
        )
        return Self.dictionaryArray(data["v_list"]).compactMap {
            Self.favoriteAlbum($0)
        }
    }

    func followedArtists(limit: Int = 100) async throws -> [QQSearchArtist] {
        let credential = try requireCredential()
        guard !credential.encryptUIN.isEmpty else { throw QQMusicError.incompleteCredential }
        let limit = max(limit, 1)
        var offset = 0
        var artists: [QQSearchArtist] = []
        var seen: Set<Int> = []
        while artists.count < limit {
            try Task.checkCancellation()
            let size = min(50, limit - artists.count)
            let data = try await authenticatedCall(
                module: "music.concern.RelationList",
                method: "GetFollowSingerList",
                parameter: ["HostUin": credential.encryptUIN, "From": offset, "Size": size]
            )
            let list = data["List"] ?? data["list"] ?? data["users"] ?? data["SingerList"]
            guard let items = list as? [[String: Any]] else { throw QQMusicError.invalidResponse }
            let page = items.compactMap(Self.followedArtist)
            guard items.isEmpty || !page.isEmpty else { throw QQMusicError.invalidResponse }
            let previousCount = artists.count
            artists.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            let nextOffset = offset + items.count
            let total = Self.int(data["Total"] ?? data["total"] ?? data["TotalNum"])
            let hasMore = Self.int(data["HasMore"] ?? data["hasMore"] ?? data["hasmore"])
                .map { $0 != 0 } ?? total.map { nextOffset < $0 } ?? (items.count == size)
            guard hasMore else { break }
            guard nextOffset > offset, artists.count > previousCount else {
                throw QQMusicError.invalidResponse
            }
            offset = nextOffset
        }
        return Array(artists.prefix(limit))
    }

    private static func followedArtist(_ item: [String: Any]) -> QQSearchArtist? {
        let mid = string(item["MID"] ?? item["mid"] ?? item["singer_mid"]) ?? ""
        let identifier = int(item["SingerID"] ?? item["singer_id"] ?? item["id"]) ?? 0
        guard let name = string(item["Name"] ?? item["name"] ?? item["singer_name"]),
              !mid.isEmpty || identifier > 0 else { return nil }
        return QQSearchArtist(
            id: identifier > 0 ? identifier : QQMusicSearchParser.stableID(mid),
            mid: mid,
            name: name,
            avatarURL: string(item["AvatarUrl"] ?? item["AvatarURL"] ?? item["avatar"] ?? item["pic"]),
            isFollowed: true
        )
    }

    // MARK: - Library writes

    func setSongLiked(songID: Int, isLiked: Bool) async throws {
        try await mutatePlaylistSongs(
            dirid: Self.likedSongsDirid,
            songID: songID,
            adding: isLiked
        )
    }

    func addSong(
        songID: Int,
        to dirid: Int,
        tid: Int = 0
    ) async throws {
        try await mutatePlaylistSongs(
            dirid: dirid,
            tid: tid,
            songID: songID,
            adding: true
        )
    }

    func removeSong(
        songID: Int,
        from dirid: Int,
        tid: Int = 0
    ) async throws {
        try await mutatePlaylistSongs(
            dirid: dirid,
            tid: tid,
            songID: songID,
            adding: false
        )
    }

    func createPlaylist(name: String) async throws -> QQSearchPlaylist {
        _ = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistBaseWrite",
            method: "AddPlaylist",
            parameter: ["dirName": name]
        )
        try Self.ensureSuccess(data)
        let result = Self.dictionary(data["result"]) ?? [:]
        let id = Self.int(result["tid"]) ?? 0
        let dirid = Self.int(result["dirId"]) ?? 0
        guard id > 0 || dirid > 0 else {
            throw QQMusicError.invalidResponse
        }
        return QQSearchPlaylist(
            id: id > 0 ? id : dirid,
            dirid: dirid,
            name: Self.string(result["dirName"]) ?? name,
            coverURL: nil,
            trackCount: 0,
            playCount: 0,
            creatorName: nil
        )
    }

    func deletePlaylist(dirid: Int) async throws {
        _ = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistBaseWrite",
            method: "DelPlaylist",
            parameter: ["dirId": dirid]
        )
        try Self.ensureSuccess(data)
    }

    func setPlaylistSubscribed(id: Int, isSubscribed: Bool) async throws {
        let credential = try requireCredential()
        guard !credential.encryptUIN.isEmpty else {
            throw QQMusicError.notLoggedIn
        }
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistFavWrite",
            method: isSubscribed ? "FavPlaylist" : "CancelFavPlaylist",
            parameter: [
                "uin": credential.encryptUIN,
                "v_playlistId": [id],
            ]
        )
        let failed = (data["v_failedPlaylistId"] as? [Any])?
            .compactMap { Self.int($0) } ?? []
        guard Self.int(data["result"]) == 0, !failed.contains(id) else {
            throw QQMusicError.response(
                code: Self.int(data["result"]) ?? -1,
                message: nil
            )
        }
    }

    func setAlbumSubscribed(id: Int, isSubscribed: Bool) async throws {
        _ = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.musicasset.AlbumFavWrite",
            method: isSubscribed ? "FavAlbum" : "CancelFavAlbum",
            parameter: ["v_albumId": [id]]
        )
        let failed = (data["v_failedAlbumId"] as? [Any])?
            .compactMap { Self.int($0) } ?? []
        guard Self.int(data["result"]) == 0, !failed.contains(id) else {
            throw QQMusicError.response(
                code: Self.int(data["result"]) ?? -1,
                message: nil
            )
        }
    }

    private func mutatePlaylistSongs(
        dirid: Int,
        tid: Int = 0,
        songID: Int,
        adding: Bool
    ) async throws {
        _ = try requireCredential()
        let data = try await authenticatedCall(
            module: "music.musicasset.PlaylistDetailWrite",
            method: adding ? "AddSonglist" : "DelSonglist",
            parameter: [
                "dirId": dirid,
                "tid": tid,
                "bFmtUtf8": true,
                "v_songInfo": [
                    ["songId": songID, "songType": 0],
                ],
            ]
        )
        try Self.ensureSuccess(data)
    }

    private func authenticatedCall(
        module: String,
        method: String,
        parameter: [String: Any]
    ) async throws -> [String: Any] {
        try await cgiCall(
            module: module,
            method: method,
            parameter: parameter,
            session: nil
        )
    }

    private func requireCredential() throws -> QQCredential {
        guard let credential, credential.isValid else {
            throw QQMusicError.notLoggedIn
        }
        return credential
    }

    private static func ensureSuccess(_ data: [String: Any]) throws {
        if let result = int(data["result"]), result != 0 {
            throw QQMusicError.response(code: result, message: nil)
        }
        if let retCode = int(data["retCode"]), retCode != 0 {
            throw QQMusicError.response(code: retCode, message: nil)
        }
    }

    private static func userPlaylist(
        _ item: [String: Any],
        creatorKeys: [String] = ["nick"]
    ) -> QQSearchPlaylist? {
        let id = int(item["dissid"]) ?? int(item["tid"])
            ?? int(item["id"]) ?? 0
        let name = string(item["title"]) ?? string(item["dissname"])
            ?? string(item["name"]) ?? string(item["dirName"])
        guard id > 0, let name, !name.isEmpty else { return nil }
        let creator = creatorKeys.compactMap { string(item[$0]) }.first
        return QQSearchPlaylist(
            id: id,
            dirid: int(item["dirid"]) ?? int(item["dirId"]) ?? 0,
            name: name,
            coverURL: string(item["picurl"])
                ?? string(item["bigpicUrl"])
                ?? string(item["cover"])
                ?? string(item["logo"]),
            trackCount: int(item["songnum"])
                ?? int(item["songNum"])
                ?? int(item["song_cnt"])
                ?? 0,
            playCount: int(item["listennum"])
                ?? int(item["playCnt"])
                ?? 0,
            creatorName: creator
        )
    }

    private static func favoriteAlbum(
        _ item: [String: Any]
    ) -> QQSearchAlbum? {
        var normalized = item
        if let singers = item["v_singer"] as? [[String: Any]] {
            normalized["singers"] = singers
        }
        return QQMusicSearchParser.album(normalized)
    }

    private func artistDescription(
        mid: String,
        session: (uid: String, sid: String)?
    ) async -> String? {
        guard let data = try? await cgiCall(
            module: "music.musichallSinger.SingerInfoInter",
            method: "GetSingerDetail",
            parameter: [
                "singer_mids": [mid],
                "group_singer": true,
                "wiki_singer": true,
                "ex_singer": true,
                "pic": true,
                "photos": true,
            ],
            session: session
        ) else {
            return nil
        }
        let list = Self.dictionaryArray(data["singer_list"])
        let extra = Self.dictionary(list.first?["ex_info"])
        return Self.string(extra?["desc"])
    }

    // MARK: - Search transports

    private func searchSongs(
        query: String,
        limit: Int,
        page: Int
    ) async throws -> [QQSearchSong] {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        ) else {
            throw QQMusicError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "p", value: String(max(page, 1))),
            URLQueryItem(name: "n", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "t", value: "0"),
        ]
        guard let url = components.url else {
            throw QQMusicError.invalidResponse
        }

        let json = try await getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let song = data["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else {
            return []
        }
        return QQMusicSearchParser.songs(list)
    }

    private func mobileSearchItems(
        query: String,
        kind: QQSearchKind,
        limit: Int,
        page: Int
    ) async throws -> [[String: Any]] {
        let session = try await anonymousSession()
        let parameter: [String: Any] = [
            "searchid": Self.makeSearchID(),
            "query": query,
            "search_type": kind.rawValue,
            "num_per_page": min(max(limit, 1), 50),
            "page_num": max(page, 1),
            "highlight": 1,
            "grp": 1,
            "selectors": [String: String](),
            "vec_selectors": [[String: Any]](),
        ]
        let data = try await cgiCall(
            module: "music.search.SearchCgiService",
            method: "DoSearchForQQMusicMobile",
            parameter: parameter,
            session: session
        )
        guard let body = data["body"] as? [String: Any] else { return [] }
        let key: String
        switch kind {
        case .songs: key = "item_song"
        case .artists: key = "singer"
        case .albums: key = "item_album"
        case .playlists: key = "item_songlist"
        }
        return body[key] as? [[String: Any]] ?? []
    }

    private func smartBoxData(_ query: String) async throws -> [String: Any] {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg"
        ) else {
            throw QQMusicError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw QQMusicError.invalidResponse
        }
        let json = try await getJSON(url: url)
        return json["data"] as? [String: Any] ?? [:]
    }

    private func smartBoxArtists(_ query: String) async -> [QQSearchArtist] {
        guard let data = try? await smartBoxData(query),
              let section = data["singer"] as? [String: Any],
              let items = section["itemlist"] as? [[String: Any]] else {
            return []
        }
        return QQMusicSearchParser.artists(items)
    }

    private func smartBoxAlbums(_ query: String) async -> [QQSearchAlbum] {
        guard let data = try? await smartBoxData(query),
              let section = data["album"] as? [String: Any],
              let items = section["itemlist"] as? [[String: Any]] else {
            return []
        }
        return QQMusicSearchParser.albums(items)
    }

    // MARK: - Anonymous session and CGI envelope

    private func anonymousSession() async throws -> (uid: String, sid: String) {
        let payload: [String: Any] = [
            "comm": buildComm(session: nil),
            "req_0": [
                "module": "music.getSession.session",
                "method": "GetSession",
                "param": [
                    "uid": "",
                    "vkey": 0,
                    "caller": 2,
                ],
            ],
        ]
        let json = try await postJSON(payload)
        guard let request = json["req_0"] as? [String: Any] else {
            throw QQMusicError.invalidResponse
        }
        let code = request["code"] as? Int ?? -1
        guard code == 0 || code == 200 else {
            throw QQMusicError.response(
                code: code,
                message: request["msg"] as? String ?? ""
            )
        }
        guard let session = request["data"] as? [String: Any],
              let payload = session["session"] as? [String: Any] else {
            throw QQMusicError.invalidResponse
        }

        let uid: String
        if let value = payload["uid"] as? Int {
            uid = String(value)
        } else if let value = payload["uid"] as? String {
            uid = value
        } else {
            uid = ""
        }
        let sid = payload["sid"] as? String ?? ""
        guard !uid.isEmpty, !sid.isEmpty else {
            throw QQMusicError.invalidResponse
        }
        return (uid, sid)
    }

    private func cgiCall(
        module: String,
        method: String,
        parameter: [String: Any],
        session: (uid: String, sid: String)? = nil
    ) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "comm": buildComm(session: session),
            "req_0": [
                "module": module,
                "method": method,
                "param": parameter,
            ],
        ]
        let json = try await postJSON(payload)
        guard let request = json["req_0"] as? [String: Any] else {
            throw QQMusicError.invalidResponse
        }
        let code = Self.int(request["code"])
            ?? Self.int(json["code"])
            ?? -1
        guard code == 0 || code == 200 else {
            let message = (request["msg"] as? String)
                ?? (json["message"] as? String)
                ?? ""
            throw QQMusicError.response(code: code, message: message)
        }
        return request["data"] as? [String: Any] ?? [:]
    }

    private func buildComm(
        session: (uid: String, sid: String)?
    ) -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let uidPart = credential?.isValid == true
            ? String(credential?.musicID ?? 0)
            : guid
        var comm: [String: Any] = [
            "ct": 11,
            "cv": "20090008",
            "v": "20090008",
            "chid": "10003505",
            "tmeAppID": "qqmusic",
            "traceid": "10002_\(uidPart)_\(timestamp)",
            "QIMEI36": qimei36,
            "OpenUDID": guid,
            "udid": guid,
            "aid": String(guid.prefix(16)),
            "os_ver": "15",
            "phonetype": "iPhone",
        ]
        if let session {
            comm["uid"] = session.uid
            comm["sid"] = session.sid
        }
        // `qq` 是账号号码，只在登录后发送。未登录时若填入别的内容（此前
        // 填的是随机设备串），QQ 会按该串把专辑、歌手、歌单搜索过滤成空，
        // 实测约四成的随机串会中招。
        if let credential, credential.isValid {
            comm["qq"] = String(credential.musicID)
            comm["authst"] = credential.musicKey
            comm["tmeLoginType"] = credential.loginType
        }
        return comm
    }

    // MARK: - HTTP

    private func postJSON(_ payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(
            url: Self.cgiURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await perform(request)
    }

    private func getJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await urlSession.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw QQMusicError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                switch httpResponse.statusCode {
                case 401: throw QQMusicError.credentialExpired(code: 401)
                case 403: throw QQMusicError.accessDenied(code: 403)
                default: throw QQMusicError.httpStatus(code: httpResponse.statusCode)
                }
            }
            guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw QQMusicError.invalidResponse
            }
            if let code = Self.int(json["code"]), code != 0, code != 200 {
                throw QQMusicError.response(
                    code: code,
                    message: json["message"] as? String ?? ""
                )
            }
            return json
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QQMusicError {
            throw error
        } catch {
            throw QQMusicError.transport(
                code: (error as? URLError)?.errorCode ?? -1
            )
        }
    }

    // MARK: - Parsing helpers

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func dictionaryArray(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    // MARK: - Identifiers

    private static func makeGUID() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func makeQIMEI36() -> String {
        let base = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let suffix = String(
            format: "%04x",
            UInt16.random(in: 0...UInt16.max)
        )
        return String((base + suffix).prefix(36))
    }

    private static func makeSearchID() -> String {
        let multiplier = Int.random(in: 1...20)
        let high = multiplier * 18_014_398_509_481_984
        let middle = Int.random(in: 0...4_194_304) * 4_294_967_296
        let clock = Int(Date().timeIntervalSince1970 * 1_000) % 86_400_000
        return String(high + middle + clock)
    }
}
