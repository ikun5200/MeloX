"""Offline checks for the QQ backend primitives.

The harness compiles the production Swift sources with small stubs, so it can
run on the CI runner before the iOS app build without a simulator.
"""

import subprocess
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "MeloX/Core/Backend/QQ/QQMusicSign.swift",
    "MeloX/Core/Backend/QQ/QQMusicSearchModels.swift",
    "MeloX/Core/Links/QQMusicLink.swift",
    "MeloX/Core/Lyrics/QQMusicLyricMatchStore.swift",
    "MeloX/Core/Lyrics/QQMusicLyricMatcher.swift",
    "MeloX/Core/Settings/Playback/MusicQuality.swift",
    "MeloX/Core/Models/Music/SongAudioAvailability.swift",
    "MeloX/Core/Sources/LXQualityMapping.swift",
    "MeloX/Core/Sources/LXStreamProbe.swift",
]

STUBS = r"""
import Foundation

enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ values: CVarArg...) -> String { key }
    static func joined(_ values: [String], separatorKey: String) -> String {
        values.joined(separator: ", ")
    }
}

enum LXPlaybackError: LocalizedError {
    case unplayableStream(String)

    var errorDescription: String? {
        switch self {
        case .unplayableStream(let reason): reason
        }
    }
}

struct LyricsSongMetadata: Hashable, Sendable {
    let id: Int
    let title: String
    let album: String
    let artist: String
    let durationSeconds: Int
}
"""

HARNESS = r"""
import Foundation

@main
struct Harness {
    static func main() {
        precondition(
            QQMusicSign.zzcSign("abc")
                == "zzc163db6e8l6noj1uu5ylcp8kabaw6rnxos4b998e04e"
        )
        precondition(
            QQMusicSign.zzcSign("{\"comm\":{\"ct\":11}}")
                == "zzc59fd0a5v8pablerq2e9axkocuvf4gymq5s0e895b63"
        )
        precondition(
            QQMusicSign.zzcSign("")
                == "zzcf0e03e5gx4qeiq5cfgdyqwu7sdqfsb5fro3aa45053"
        )

        // The chosen tier first, then one QQ step down at a time.
        precondition(
            LXQualityMapping.ladder(from: .lossless)
                == [.lossless, .high, .standard]
        )
        precondition(
            LXQualityMapping.ladder(from: .standard) == [.standard]
        )
        // A source is asked for the names it declares.
        precondition(
            LXQualityMapping.sourceNames(for: .hiResolution)
                == ["hires", "flac24bit"]
        )
        precondition(
            LXQualityMapping.sourceNames(
                for: .high,
                declared: ["128k", "320k", "flac"]
            ) == ["320k"]
        )
        precondition(
            LXQualityMapping.sourceNames(for: .standard, declared: [])
                == ["128k"]
        )

        // The bytes decide what a stream is: QQ's own servers label their
        // FLAC files `audio/x-ogg`.
        precondition(LXStreamProbe.container(of: Array("fLaC".utf8)) == .flac)
        precondition(LXStreamProbe.container(of: Array("OggS".utf8)) == .ogg)
        precondition(
            LXStreamProbe.container(of: [0xFF, 0xFB, 0x90, 0x64]) == .mpeg
        )
        precondition(
            LXStreamProbe.container(of: Array("<html>".utf8)) == .text
        )
        let flacHead: [UInt8] = [
            0x66, 0x4C, 0x61, 0x43, 0x80, 0x00, 0x00, 0x22,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x17, 0x70, 0x03, 0x70, 0x01, 0x3B,
            0xCE, 0x1B,
        ]
        precondition(
            LXStreamProbe.flacInfo(in: flacHead)
                == LXStreamProbe.FLACInfo(
                    sampleRate: 96_000,
                    channelCount: 2,
                    bitsPerSample: 24,
                    duration: 215.58961458333334
                )
        )

        // A file whose length is one of the song's encodings is that tier.
        let availability = SongAudioAvailability(encodingSizes: [
            .standard: 3_700_000,
            .high: 9_000_000,
            .lossless: 45_000_000,
        ])
        precondition(availability.quality(ofFileSized: 45_000_000) == .lossless)
        precondition(availability.quality(ofFileSized: 45_000_001) == nil)
        precondition(availability.smallestFileSize == 3_700_000)
        precondition(availability.supports(.hiResolution) == false)
        precondition(
            LXQualityMapping.quality(for: "atmos_plus")
                == .immersiveSurround
        )
        precondition(LXQualityMapping.quality(for: "unknown") == nil)
        precondition(
            LXQualityMapping.bitrate(for: .high) == 320_000
        )
        precondition(
            LXQualityMapping.format(
                for: URL(string: "https://example.com/a.flac")!,
                quality: .lossless
            ) == "flac"
        )
        precondition(
            LXQualityMapping.format(
                for: URL(string: "https://example.com/stream")!,
                quality: .ultraClearMaster
            ) == "flac"
        )

        let lyricMetadata = LyricsSongMetadata(
            id: 405007729,
            title: "愿与愁",
            album: "重拾_快乐",
            artist: "林俊杰",
            durationSeconds: 231
        )
        let lyricCandidate = QQMusicTrackMatch(
            id: 405007729,
            title: "愿与愁",
            album: "重拾_快乐",
            artist: "林俊杰",
            durationSeconds: 0
        )
        precondition(
            QQMusicLyricMatcher.bestCandidate(
                in: [lyricCandidate],
                for: lyricMetadata
            )?.id == 405007729
        )
        let wrongDuration = QQMusicTrackMatch(
            id: 1,
            title: "愿与愁",
            album: "重拾_快乐",
            artist: "林俊杰",
            durationSeconds: 300
        )
        precondition(
            QQMusicLyricMatcher.bestCandidate(
                in: [wrongDuration],
                for: lyricMetadata
            ) == nil
        )
        let wrongArtist = QQMusicTrackMatch(
            id: 2,
            title: "愿与愁",
            album: "重拾_快乐",
            artist: "其他歌手",
            durationSeconds: 231
        )
        precondition(
            QQMusicLyricMatcher.bestCandidate(
                in: [wrongArtist],
                for: lyricMetadata
            ) == nil
        )

        precondition(
            QQMusicSearchParser.stableID("same-mid")
                == QQMusicSearchParser.stableID("same-mid")
        )
        precondition(
            QQMusicSearchParser.stableID("a")
                != QQMusicSearchParser.stableID("b")
        )
        precondition(
            QQMusicSearchParser.stableID64("1!abc*")
                == QQMusicSearchParser.stableID64("1!abc*")
        )

        let songItem: [String: Any] = [
            "songid": 123,
            "songmid": "mid123",
            "songname": "<em>晴天</em>",
            "singer": [
                [
                    "singerID": 7,
                    "singerMid": "singer-mid",
                    "singerName": "周杰伦",
                ],
            ],
            "album": [
                "id": 9,
                "mid": "album-mid",
                "name": "叶惠美",
                "pic": "http://y.gtimg.cn/cover.jpg",
            ],
            "interval": 269,
            "vid": "mv-vid",
        ]
        guard let parsedSong = QQMusicSearchParser.song(songItem) else {
            preconditionFailure("song fixture should parse")
        }
        precondition(parsedSong.id == 123)
        precondition(parsedSong.mid == "mid123")
        precondition(parsedSong.name == "晴天")
        precondition(parsedSong.albumID == 9)
        precondition(parsedSong.albumMID == "album-mid")
        precondition(parsedSong.durationSeconds == 269)
        precondition(parsedSong.musicVideoMID == "mv-vid")
        precondition(parsedSong.artists.first?.name == "周杰伦")

        let playlistItem: [String: Any] = [
            "dissid": 456,
            "dirid": 789,
            "dissname": "测试歌单",
            "logo": "http://y.gtimg.cn/playlist.jpg",
            "songnum": 12,
            "listennum": 34,
            "nickname": "创建者",
        ]
        guard let parsedPlaylist =
            QQMusicSearchParser.playlist(playlistItem) else {
            preconditionFailure("playlist fixture should parse")
        }
        precondition(parsedPlaylist.id == 456)
        precondition(parsedPlaylist.dirid == 789)
        precondition(parsedPlaylist.trackCount == 12)
        precondition(parsedPlaylist.creatorName == "创建者")

        precondition(
            QQMusicLinkParser.parse(
                "https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV"
            ) == .song(mid: "0039MnYb0qxYhV")
        )
        precondition(
            QQMusicLinkParser.parse(
                "https://y.qq.com/n/ryqq/albumDetail/0024bjiL2aocxT"
            ) == .album(mid: "0024bjiL2aocxT")
        )
        precondition(
            QQMusicLinkParser.parse(
                "https://y.qq.com/n/ryqq/playlist/7011264340"
            ) == .playlist(id: 7_011_264_340)
        )
        precondition(
            QQMusicLinkParser.parse(
                "https://y.qq.com/n/ryqq/toplist/26"
            ) == .toplist(id: 26)
        )
        precondition(
            QQMusicLinkParser.parse("https://example.com/songDetail/x")
                == nil
        )
    }
}
"""


class QQBackendChecks(unittest.TestCase):
    def test_sign_and_quality_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for source in SOURCES:
                target = work / Path(source).name
                target.write_text(
                    (ROOT / source).read_text(encoding="utf-8"),
                    encoding="utf-8",
                )
            (work / "Stubs.swift").write_text(STUBS, encoding="utf-8")
            (work / "Harness.swift").write_text(HARNESS, encoding="utf-8")
            binary = work / "qq-checks"
            compile_result = subprocess.run(
                [
                    "swiftc",
                    "-O",
                    "-o",
                    str(binary),
                    *[str(work / Path(source).name) for source in SOURCES],
                    str(work / "Stubs.swift"),
                    str(work / "Harness.swift"),
                ],
                cwd=work,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stderr,
            )
            run_result = subprocess.run(
                [str(binary)],
                cwd=work,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                run_result.stderr,
            )


class LXScriptRuntimeChecks(unittest.TestCase):
    def test_fake_source_initializes_and_resolves(self):
        fake_script = r"""
lx.on(lx.EVENT_NAMES.request, function (request) {
    if (request.action === 'musicUrl'
        && request.source === 'tx'
        && request.info.type === '128k') {
        return 'https://example.com/a.mp3';
    }
    return Promise.reject(new Error('unsupported quality'));
});
lx.send(lx.EVENT_NAMES.inited, {
    sources: {
        tx: {
            name: 'TX',
            type: 'music',
            actions: ['musicUrl'],
            qualitys: ['128k', '320k']
        }
    }
});
"""
        harness = r"""
import Foundation

@main
struct RuntimeHarness {
    static func main() async {
        do {
            let preload = try String(
                contentsOfFile: CommandLine.arguments[1],
                encoding: .utf8
            )
            let runtime = LXScriptRuntime(preload: preload)
            let script = try String(
                contentsOfFile: CommandLine.arguments[2],
                encoding: .utf8
            )
            let descriptor = try await runtime.initialize(
                script: script
            )
            guard let tx = descriptor.qqSource else {
                preconditionFailure("tx source missing")
            }
            precondition(tx.qualitys == ["128k", "320k"])
            let url = try await runtime.resolveMusicURL(
                musicInfo: ["songmid": "mid", "name": "song"],
                quality: "128k"
            )
            precondition(url == "https://example.com/a.mp3")
            do {
                _ = try await runtime.resolveMusicURL(
                    musicInfo: ["songmid": "mid"],
                    quality: "flac"
                )
                preconditionFailure("unsupported quality should fail")
            } catch {
                // expected
            }
            runtime.shutdown()
        } catch {
            print("runtime error:", error)
            exit(1)
        }
    }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = ROOT / "MeloX/Core/Sources/LXScriptRuntime.swift"
            (work / source.name).write_text(
                source.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (work / "Harness.swift").write_text(harness, encoding="utf-8")
            script_path = work / "fake-source.js"
            script_path.write_text(fake_script, encoding="utf-8")
            binary = work / "lx-checks"
            compile_result = subprocess.run(
                [
                    "swiftc",
                    "-O",
                    "-o",
                    str(binary),
                    str(work / source.name),
                    str(work / "Harness.swift"),
                ],
                cwd=work,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stderr,
            )
            run_result = subprocess.run(
                [
                    str(binary),
                    str(ROOT / "MeloX/Resources/LX/LXScriptPreload.js"),
                    str(script_path),
                ],
                cwd=work,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                run_result.stderr + run_result.stdout,
            )


if __name__ == "__main__":
    unittest.main()
