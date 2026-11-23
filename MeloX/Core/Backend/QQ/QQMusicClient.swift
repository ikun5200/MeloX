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
