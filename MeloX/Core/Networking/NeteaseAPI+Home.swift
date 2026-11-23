import Foundation

enum PersonalFMMode: String {
    case familiar = "FAMILIAR"
    case explore = "EXPLORE"
}

extension NeteaseAPI {
    func toplistDetail(
        id: Int,
        trackLimit: Int = 100
    ) async throws -> Playlist {
        guard isUsingSourceResolver else {
            return try await playlist(id: id, trackLimit: trackLimit)
        }
        let detail = try await qq.toplistDetail(
            topID: id,
            limit: min(max(trackLimit, 1), 100)
        )
        return QQMusicMapper.toplistDetail(detail)
    }

    func homePage(
        refresh: Bool = false,
        cursor: String? = nil
    ) async throws -> HomePagePayload {
        if isUsingSourceResolver {
            // QQ 没有等价的首页楼层接口，直接使用本地推荐回退数据。
            return HomePagePayload()
        }
        // The original module permits eapi through RequestBaseConfig.crypto.
        var data: [String: Any] = ["refresh": refresh]
        if let cursor {
            data["cursor"] = cursor
        }

        let response: HomePageResponse = try await client.eapi(
            "/api/homepage/block/page",
            data: data,
            authenticated: true
        )
        try validate(
            responseCode: response.code,
            message: response.message ?? L10n.string("ui.error.home.load_failed")
        )
        guard let payload = response.data else {
            throw APIError.invalidResponse
        }
        return payload
    }

    func topSongs(
        region: HomeMusicRegion,
        limit: Int = 12
    ) async throws -> [Song] {
        if isUsingSourceResolver {
            let topID = region == .all ? 26 : 4
            let detail = try await qq.toplistDetail(
                topID: topID,
                limit: limit
            )
            return detail.songs.map(QQMusicMapper.song)
        }
        // Mirrors @neteaseapireborn/api/module/top_song.js.
        let response: HomeTopSongsResponse =
            try await homeCompatibleWeapi(
                "/api/v1/discovery/new/songs",
                data: [
                    "areaId": region.areaID,
                    "total": true,
                ]
            )
        try validate(
            responseCode: response.code,
            message: response.message
        )
        return Array(
            response.data
                .filter { $0.id > 0 }
                .prefix(min(max(limit, 1), 100))
        )
    }

    func personalizedNewSongs(
        region: HomeMusicRegion,
        limit: Int = 12
    ) async throws -> [Song] {
        if isUsingSourceResolver {
            let detail = try await qq.toplistDetail(
                topID: 427,
                limit: limit
            )
            return detail.songs.map(QQMusicMapper.song)
        }
        // Mirrors @neteaseapireborn/api/module/personalized_newsong.js.
        let response: HomePersonalizedNewSongsResponse =
            try await homeCompatibleWeapi(
                "/api/personalized/newsong",
                data: [
                    "type": "recommend",
                    "limit": min(max(limit, 1), 100),
                    "areaId": region.areaID,
                ]
            )
        try validate(
            responseCode: response.code,
            message: response.message
        )
        return response.result
            .compactMap(\.song)
            .filter { $0.id > 0 }
    }

    func recommendedPodcastPrograms(
        limit: Int = 12
    ) async throws -> [PodcastProgram] {
        if isUsingSourceResolver { return [] }
        // Mirrors @neteaseapireborn/api/module/program_recommend.js.
        let response: HomeRecommendedProgramsResponse =
            try await homeCompatibleWeapi(
                "/api/program/recommend/v1",
                data: [
                    "limit": min(max(limit, 1), 50),
                    "offset": 0,
                ]
            )
        try validate(
            responseCode: response.code,
            message: response.message
        )
        return response.programs.filter { $0.id > 0 }
    }

    func personalFM(
        mode: PersonalFMMode = .explore,
        limit: Int = 30
    ) async throws -> [Song] {
        if isUsingSourceResolver {
            let detail = try await qq.toplistDetail(
                topID: 62,
                limit: limit
            )
            return detail.songs.map(QQMusicMapper.song)
        }
        // Mirrors @neteaseapireborn/api/module/personal_fm_mode.js.
        let response: PersonalFMResponse = try await client.eapi(
            "/api/v1/radio/get",
            data: [
                "mode": mode.rawValue,
                "limit": min(max(limit, 1), 50),
            ]
        )
        guard response.code == 200 else {
            throw APIError.server(
                statusCode: response.code,
                message: response.message ?? L10n.string("ui.error.private_radio.start_failed")
            )
        }
        return response.data.filter { $0.id > 0 }
    }

    private func homeCompatibleWeapi<Response: Decodable>(
        _ path: String,
        data: [String: Any]
    ) async throws -> Response {
        do {
            return try await client.weapi(path, data: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch APIError.emptyResponse {
            return try await client.eapi(
                path,
                data: data,
                authenticated: true
            )
        }
    }

}
