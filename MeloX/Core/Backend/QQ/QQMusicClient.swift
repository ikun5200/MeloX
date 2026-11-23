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
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> QQPlaylistDetail {
        let session = try await anonymousSession()
        let data = try await cgiCall(
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            parameter: [
                "disstid": id,
                "dirid": 0,
                "tag": true,
                "song_begin": offset,
                "song_num": limit,
                "userinfo": true,
                "orderlist": true,
                "onlysonglist": false,
            ],
            session: session
        )

        let info = Self.dictionary(data["dirinfo"]) ?? [:]
        let creator = Self.dictionary(info["creator"]) ?? [:]
        let songs = QQMusicSearchParser.songs(
            Self.dictionaryArray(data["songlist"])
        )
        let total = Self.int(data["total_song_num"])
            ?? Self.int(info["songnum"])
            ?? songs.count

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
                || total > offset + songs.count
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
        let session = try await anonymousSession()
        let infoData = try await cgiCall(
            module: "music.UnifiedHomepage.UnifiedHomepageSrv",
            method: "GetHomepageHeader",
            parameter: ["SingerMid": mid],
            session: session
        )
        let info = Self.dictionary(infoData["Info"]) ?? [:]
        let singer = Self.dictionary(info["Singer"])
            ?? Self.dictionary(info["BaseInfo"])
            ?? [:]

        let artist = QQMusicSearchParser.artist(singer)
            ?? QQSearchArtist(
                id: Self.int(singer["SingerID"]) ?? 0,
                mid: mid,
                name: Self.string(singer["Name"]) ?? "",
                avatarURL: Self.string(singer["Avatar"])
                    ?? Self.string(singer["SingerPic"]),
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

    private func artistDescription(
        mid: String,
        session: (uid: String, sid: String)
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
            throw QQMusicError.server(
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
        session: (uid: String, sid: String)
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
        let code = request["code"] as? Int
            ?? json["code"] as? Int
            ?? -1
        guard code == 0 || code == 200 else {
            let message = (request["msg"] as? String)
                ?? (json["message"] as? String)
                ?? ""
            throw QQMusicError.server(code: code, message: message)
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
            "qq": credential?.isValid == true
                ? String(credential?.musicID ?? 0)
                : guid,
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
        if let credential, credential.isValid {
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
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw QQMusicError.invalidResponse
            }
            guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw QQMusicError.invalidResponse
            }
            if let code = json["code"] as? Int, code != 0 {
                throw QQMusicError.server(
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
