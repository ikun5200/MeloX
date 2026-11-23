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
    "MeloX/Core/Settings/Playback/MusicQuality.swift",
    "MeloX/Core/Sources/LXQualityMapping.swift",
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

struct SongAudioAvailability {
    func supports(apiLevel: String) -> Bool? { true }
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

        precondition(
            LXQualityMapping.candidates(
                for: .ultraClearMaster,
                supported: ["master", "flac", "320k"]
            ) == ["master", "flac", "320k"]
        )
        precondition(
            LXQualityMapping.candidates(
                for: .high,
                supported: ["flac"]
            ) == ["flac"]
        )
        precondition(
            LXQualityMapping.candidates(
                for: .standard,
                supported: []
            ) == ["128k"]
        )
        precondition(
            LXQualityMapping.quality(for: "atmos_plus")
                == .immersiveSurround
        )
        precondition(LXQualityMapping.quality(for: "unknown") == nil)
        precondition(
            LXQualityMapping.bitrate(for: "320k") == 320_000
        )
        precondition(
            LXQualityMapping.format(
                for: URL(string: "https://example.com/a.flac")!,
                quality: "flac"
            ) == "flac"
        )
        precondition(
            LXQualityMapping.format(
                for: URL(string: "https://example.com/stream")!,
                quality: "master"
            ) == "flac"
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


if __name__ == "__main__":
    unittest.main()
