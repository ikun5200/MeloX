#if DEBUG && targetEnvironment(simulator)
import Foundation

/// An isolated account and an in-process music service for UI acceptance.
/// No fixture request is allowed to reach the network or a real QQ account.
nonisolated enum MeloXLibraryUIFixture {
    static let accountID = 9_000_000_000_001
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "MeloXLibraryFixture") }
    static var failsSomeWrites: Bool { UserDefaults.standard.bool(forKey: "MeloXLibraryFixturePartialFailure") }
    static var expiresArtists: Bool { UserDefaults.standard.bool(forKey: "MeloXLibraryFixtureExpired") || hasNoRefresh }
    static var hasNoRefresh: Bool { UserDefaults.standard.bool(forKey: "MeloXLibraryFixtureNoRefresh") }

    static var defaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "azki.moye.MeloX.LibraryFixture")!
        if UserDefaults.standard.bool(forKey: "MeloXLibraryFixtureReset") {
            defaults.removePersistentDomain(forName: "azki.moye.MeloX.LibraryFixture")
        }
        let credential = QQCredential(
            musicID: accountID,
            musicKey: "fixture-old-key",
            refreshKey: hasNoRefresh ? "" : "fixture-refresh-key",
            refreshToken: hasNoRefresh ? "" : "fixture-refresh-token",
            encryptUIN: "fixture-euin",
            nickName: "MeloX 界面验收"
        )
        defaults.set(try? JSONEncoder().encode(credential), forKey: "qqMusicCredential")
        defaults.set(true, forKey: "melox.hasCompletedOnboarding")
        defaults.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, forKey: "appReleaseNotes.lastPresentedVersion")
        defaults.set(true, forKey: "appRecommendation.hasPresentedPrompt")
        defaults.set(false, forKey: "checksUpdatesOnLaunch")
        defaults.set(false, forKey: "recognizesClipboardLinksOnLaunch")
        defaults.set(false, forKey: "startsHeartModeOnLaunch")
        return defaults
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static var requestCount: Int { LibraryFixtureURLProtocol.state.requestCount }
}

nonisolated private final class LibraryFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var songIDs = Array(900_000..<900_020)
    private var renewed = false
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    func response(to request: URLRequest) -> Data {
        lock.withLock {
            requests += 1
            let payload = Self.requestPayload(request)
            let operation = payload["req_0"] as? [String: Any] ?? [:]
            let method = operation["method"] as? String ?? ""
            let parameter = operation["param"] as? [String: Any] ?? [:]
            var data: [String: Any] = [:]
            var code = 0
            switch method {
            case "GetLoginUserInfo":
                data = ["nick": "MeloX 界面验收", "musicid": MeloXLibraryUIFixture.accountID]
            case "GetPlaylistByUin":
                data = ["v_playlist": [["tid": 990_001, "dirid": 1, "title": "界面验收歌单", "song_cnt": 0, "nick": "MeloX"]]]
            case "CgiGetPlaylistFavInfo", "CgiGetAlbumFavInfo":
                data = ["v_list": []]
            case "GetFollowSingerList":
                if MeloXLibraryUIFixture.expiresArtists, !renewed {
                    code = 1000
                } else {
                    data = ["Total": 2, "HasMore": 0, "List": [
                        ["SingerID": 910_001, "MID": "fixture-artist-1", "Name": "MeloX"],
                        ["SingerID": 910_002, "MID": "fixture-artist-2", "Name": "界面验收艺人"],
                    ]]
                }
            case "Login":
                renewed = true
                data = ["musicid": MeloXLibraryUIFixture.accountID, "musickey": "fixture-new-key", "encryptUin": "fixture-euin", "refresh_key": "fixture-refresh-key", "refresh_token": "fixture-refresh-token", "loginType": 0]
            case "CgiGetDiss":
                let offset = parameter["song_begin"] as? Int ?? 0
                let count = parameter["song_num"] as? Int ?? 100
                let page = songIDs.dropFirst(max(offset, 0)).prefix(max(count, 0))
                data = ["dirinfo": ["id": 0, "dirid": 201, "title": "收藏歌曲", "songnum": songIDs.count], "total_song_num": songIDs.count,
                        "hasmore": offset + page.count < songIDs.count ? 1 : 0,
                        "songlist": page.map(Self.song)]
            case "DelSonglist", "AddSonglist":
                let items = parameter["v_songInfo"] as? [[String: Any]] ?? []
                let ids = items.compactMap { $0["songId"] as? Int }
                if MeloXLibraryUIFixture.failsSomeWrites, ids.contains(900_002) {
                    code = 500
                } else if method == "DelSonglist", parameter["dirId"] as? Int == 201 {
                    songIDs.removeAll { ids.contains($0) }
                }
                data = ["result": code]
            default:
                data = [:]
            }
            let response: [String: Any] = ["code": 0, "req_0": ["code": code, "data": data]]
            return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        }
    }

    private static func song(_ id: Int) -> [String: Any] {
        let names = ["此刻的音乐", "午后漫游", "夜色与旋律", "重新出发", "晴空", "晚安时刻"]
        let index = id - 900_000
        return ["id": id, "mid": "FIXTURE\(id)", "name": "\(names[index % names.count]) \(index / names.count + 1)",
                "singer": [["id": 910_001, "mid": "fixture-artist-1", "name": "MeloX"]],
                "album": ["id": 920_001, "mid": "", "name": "界面验收"], "interval": 180]
    }

    private static func requestPayload(_ request: URLRequest) -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        } else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

nonisolated private final class LibraryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = LibraryFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.state.response(to: request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
