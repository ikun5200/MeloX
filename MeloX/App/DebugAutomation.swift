#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Lets the host drive playback while the app runs in the simulator.
///
/// The host writes one command, shaped like a URL path and query, to
/// `Documents/debug-command.txt`; this picks it up, makes the same
/// `PlayerStore` call the UI makes, and writes the resulting state to
/// `Documents/debug-state.json`. A file is used instead of a URL scheme
/// because opening a custom URL from the host raises a system confirmation.
/// See `Tools/Tests/sim_rig`. Excluded from device and Release builds.
@MainActor
enum MeloXDebugAutomation {
    private static var pollTask: Task<Void, Never>?

    /// The byte size of each fixture the rig's server holds, by file name.
    /// The test songs report these as QQ would, so that a returned stream
    /// can be told from another by its length.
    private static var fixtureSizes: [String: Int64] = [:]

    static func start(
        player: PlayerStore,
        api: NeteaseAPI,
        settings: AppSettings,
        downloads: DownloadStore
    ) {
        guard pollTask == nil,
              let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else {
            return
        }
        let commandURL = documents.appending(path: "debug-command.txt")
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let command = try? String(
                    contentsOf: commandURL,
                    encoding: .utf8
                ) else {
                    continue
                }
                try? FileManager.default.removeItem(at: commandURL)
                run(
                    command.trimmingCharacters(in: .whitespacesAndNewlines),
                    player: player,
                    api: api,
                    settings: settings,
                    downloads: downloads
                )
            }
        }
    }

    private static func run(
        _ command: String,
        player: PlayerStore,
        api: NeteaseAPI,
        settings: AppSettings,
        downloads: DownloadStore
    ) {
        guard let components = URLComponents(string: "debug:///\(command)") else {
            return
        }
        // The rig's fixtures are test tones; the host has no use for them.
        player.debugMuteOutput()
        let action = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        switch action {
        case "play":
            Task {
                await loadFixtureSizes(from: query["sizes"])
                let songs = testSongs
                let index = min(
                    max(Int(query["index"] ?? "") ?? 0, 0),
                    songs.count - 1
                )
                await player.play(songs[index], in: songs)
            }
        case "quality":
            guard let quality = MusicQuality.allCases.first(where: {
                $0.rawValue == query["q"] || "\($0)" == query["q"]
            }) else {
                break
            }
            switch query["scope"] {
            case "wifi":
                player.selectPlaybackQuality(quality, forCellularData: false)
            case "cellular":
                player.selectPlaybackQuality(quality, forCellularData: true)
            default:
                player.selectSessionPlaybackQuality(quality)
            }
        case "toggle":
            player.togglePlayback()
        case "next":
            Task { await player.next() }
        case "previous":
            Task { await player.previous() }
        case "seek":
            player.seek(to: Double(query["to"] ?? "") ?? 0)
        case "issue":
            player.debugRaisePlaybackIssue()
        case "downloadissue":
            downloads.debugRaiseError()
        case "burst":
            // Rapid play taps, as from a finger hammering the button.
            let count = Int(query["n"] ?? "") ?? 6
            let gap = Int(query["gap"] ?? "") ?? 60
            Task {
                for _ in 0..<count {
                    player.togglePlayback()
                    try? await Task.sleep(for: .milliseconds(gap))
                }
            }
        case "stress":
            // What an impatient hand does: scrubbing, switching quality and
            // skipping, each before the last has settled.
            let count = Int(query["n"] ?? "") ?? 40
            let gap = Int(query["gap"] ?? "") ?? 120
            Task {
                for step in 0..<count {
                    switch step % 5 {
                    case 0, 2:
                        player.seek(to: Double.random(in: 0...80))
                    case 1:
                        player.selectSessionPlaybackQuality(
                            MusicQuality.allCases.randomElement() ?? .high
                        )
                    case 3:
                        player.togglePlayback()
                    default:
                        if step % 20 == 4 {
                            await player.next()
                        } else {
                            player.togglePlayback()
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(gap))
                }
            }
        case "present":
            // The same route a Live Activity tap takes to open the player.
            DeepLinkRouter.shared.handleLiveActivityContinuation()
        case "setting":
            apply(query, to: settings, player: player)
        default:
            break
        }

        writeState(player: player, api: api, settings: settings)
    }

    /// Songs the rig's server knows by `mid`. Their availability mirrors what
    /// QQ reports per song; the server decides what the source answers.
    private static var testSongs: [Song] {
        func song(
            _ index: Int,
            _ name: String,
            _ mid: String,
            _ sizes: [MusicQuality: Int64]?,
            seconds: Int = 90
        ) -> Song {
            Song(
                id: 910_000 + index,
                name: name,
                artists: [Artist(id: 910_000, name: "测试台")],
                album: Album(id: 910_000 + index, name: "音质测试"),
                durationMS: seconds * 1_000,
                audioAvailability: sizes.map(
                    SongAudioAvailability.init(encodingSizes:)
                ) ?? .unknown,
                mid: mid
            )
        }
        let files: [MusicQuality: String] = [
            .standard: "M500.mp3",
            .high: "M800.mp3",
            .lossless: "F000.flac",
            .hiResolution: "RS01.flac",
            .highDefinitionSurround: "Q000.flac",
            .immersiveSurround: "Q001.flac",
            .ultraClearMaster: "AI00.flac",
        ]
        let everything = files.mapValues { fixtureSizes[$0] ?? 1 }
        func only(_ tiers: MusicQuality...) -> [MusicQuality: Int64] {
            everything.filter { tiers.contains($0.key) }
        }
        var withoutHiRes = everything
        withoutHiRes[.hiResolution] = nil
        return [
            song(0, "全档位", "TESTALL", everything),
            song(1, "无 Hi-Res", "TESTNOHIRES", withoutHiRes),
            song(2, "仅 MP3", "TESTMP3", only(.standard, .high)),
            song(3, "档位未知", "TESTUNKNOWN", nil),
            song(4, "仅标准", "TEST128", only(.standard)),
            song(5, "全档位二", "TESTALL2", everything),
            // Listed as longer than any fixture, as a song is longer than
            // the preview clip a source may return for it.
            song(6, "档位未知长歌", "TESTLONG", nil, seconds: 140),
        ]
    }

    private static func loadFixtureSizes(from address: String?) async {
        guard fixtureSizes.isEmpty,
              let address,
              let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let sizes = try? JSONDecoder().decode(
                [String: Int64].self,
                from: data
              ) else {
            return
        }
        fixtureSizes = sizes
    }

    private static func apply(
        _ query: [String: String],
        to settings: AppSettings,
        player: PlayerStore
    ) {
        if let value = query["shrinksPausedArtwork"] {
            settings.shrinksPausedArtwork = value == "1"
        }
        if let value = query["appleMusicQuality"] {
            player.setUsesAppleMusicQualityOptions(value == "1")
        }
    }

    private static func writeState(
        player: PlayerStore,
        api: NeteaseAPI,
        settings: AppSettings
    ) {
        let state: [String: Any] = [
            "song": player.currentSong?.name ?? "",
            "mid": player.currentSong?.mid ?? "",
            "isPlaying": player.isPlaying,
            "isLoading": player.isLoading,
            "progress": (player.estimatedProgress() * 10).rounded() / 10,
            "playing": player.effectivePlaybackQuality.map { "\($0)" } ?? "",
            "requested": "\(api.playbackQuality)",
            "offered": player.playbackQualityOptions.map { quality in
                player.currentSongOffers(quality) == false
                    ? "\(quality)(无)"
                    : "\(quality)"
            },
            "issue": player.playbackIssue?.message ?? "",
            "notice": player.playbackQualityNotice ?? "",
            "switching": player.isSwitchingPlaybackQuality,
            "writtenAt": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else {
            return
        }
        try? data.write(
            to: directory.appending(path: "debug-state.json"),
            options: .atomic
        )
    }
}
#endif
