import Foundation

nonisolated enum LXPlaybackError: LocalizedError, Sendable {
    case missingSongMID
    case noSource
    case invalidURL
    case noSourceResolved(String?)

    var errorDescription: String? {
        switch self {
        case .missingSongMID:
            "这首歌缺少 QQ 音乐 songmid，无法解析播放地址。"
        case .noSource:
            "没有启用任何支持 QQ 音乐的洛雪源。"
        case .invalidURL:
            "洛雪源返回了无效的播放地址。"
        case .noSourceResolved(let message):
            if let message, !message.isEmpty {
                "所有洛雪源都无法解析播放地址：\(message)"
            } else {
                "所有洛雪源都无法解析播放地址。"
            }
        }
    }
}

/// 按优先级依次调用已启用的洛雪源，把 QQ 歌曲解析成可播放 URL。
@MainActor
final class LXPlaybackResolver {
    private struct CachedSource {
        let source: PlaybackSource
        let date: Date
    }

    private let store: LXSourceStore
    private let session: URLSession
    private let cacheLifetime: TimeInterval = 240

    private var runtimes: [UUID: LXScriptRuntime] = [:]
    private var cache: [String: CachedSource] = [:]

    init(store: LXSourceStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    var supportedQualities: [MusicQuality] {
        let declared = Set(
            store.enabledQQSources.flatMap { $0.qqQualities }
        )
        guard !declared.isEmpty else {
            return MusicQuality.allCases
        }
        let mapped = declared.compactMap {
            LXQualityMapping.quality(for: $0)
        }
        guard !mapped.isEmpty else { return MusicQuality.allCases }
        return MusicQuality.allCases.filter { mapped.contains($0) }
    }

    func resolve(
        song: Song,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        let songMID = song.mid.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !songMID.isEmpty else {
            throw LXPlaybackError.missingSongMID
        }

        let cacheKey = "\(songMID)#\(quality.rawValue)"
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.source
        }

        let sources = store.enabledQQSources
        guard !sources.isEmpty else {
            throw LXPlaybackError.noSource
        }

        let musicInfo = musicInfo(for: song)
        var lastError: Error?

        for source in sources {
            do {
                let runtime = try await runtime(for: source)
                let qualities = LXQualityMapping.candidates(
                    for: quality,
                    supported: source.qqQualities
                )

                for candidate in qualities {
                    do {
                        let rawURL = try await runtime.resolveMusicURL(
                            musicInfo: musicInfo,
                            quality: candidate
                        )
                        guard let url = secureURL(rawURL) else {
                            throw LXPlaybackError.invalidURL
                        }
                        let playbackSource = PlaybackSource(
                            url: url,
                            bitrate: LXQualityMapping.bitrate(
                                for: candidate
                            ),
                            format: LXQualityMapping.format(
                                for: url,
                                quality: candidate
                            ),
                            quality: LXQualityMapping.quality(
                                for: candidate
                            ) ?? quality,
                            headers: [:],
                            sourceName: source.name,
                            qualityVerified: false
                        )
                        cache[cacheKey] = CachedSource(
                            source: playbackSource,
                            date: Date()
                        )
                        return playbackSource
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                runtimes[source.id] = nil
                store.updateAfterRuntimeFailure(source, error: error)
            }
        }

        throw LXPlaybackError.noSourceResolved(
            lastError?.localizedDescription
        )
    }

    func invalidate(sourceID: UUID? = nil) {
        if let sourceID {
            runtimes[sourceID]?.shutdown()
            runtimes[sourceID] = nil
        } else {
            runtimes.values.forEach { $0.shutdown() }
            runtimes.removeAll()
        }
        cache.removeAll()
    }

    func shutdown() {
        invalidate()
    }

    private func runtime(for source: LXSource) async throws -> LXScriptRuntime {
        if let existing = runtimes[source.id] {
            return existing
        }

        let preload = try store.loadPreload()
        let runtime = LXScriptRuntime(
            preload: preload,
            session: session
        )
        do {
            _ = try await runtime.initialize(
                script: source.rawScript,
                info: LXScriptInfo(
                    name: source.name,
                    description: "",
                    version: source.version,
                    author: source.author,
                    homepage: source.homepage,
                    rawScript: source.rawScript
                )
            )
        } catch {
            runtime.shutdown()
            throw error
        }
        runtimes[source.id] = runtime
        return runtime
    }

    private func musicInfo(for song: Song) -> [String: Any] {
        var info: [String: Any] = [
            "source": "tx",
            "songmid": song.mid,
            "id": song.id,
            "name": song.name,
            "singer": song.artistText,
            "albumName": song.album?.name ?? "",
            "interval": max(song.durationMS / 1_000, 0),
        ]
        if let mediaMID = song.mediaMID, !mediaMID.isEmpty {
            info["media_mid"] = mediaMID
            info["strMediaMid"] = mediaMID
        }
        if let album = song.album {
            info["albumId"] = album.id
            info["albumMid"] = album.mid
        }
        if let mvID = song.musicVideoID {
            info["mvid"] = mvID
        }
        if let mvMID = song.musicVideoMID {
            info["vid"] = mvMID
        }
        return info
    }

    private func secureURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let url = components.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
