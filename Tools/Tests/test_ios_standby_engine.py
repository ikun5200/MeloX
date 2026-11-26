"""Host-run the iOS engine, controller and deck with a manually driven decoder.

python3 Tools/Tests/test_ios_standby_engine.py  (macOS Swift toolchain, no device or network)
"""
from pathlib import Path
import subprocess
import tempfile
import unittest


PLAYBACK = Path(__file__).resolve().parents[2] / "MeloX/Core/Playback"

# Only the hardware/network boundary is simulated. In particular pause, seek,
# cancellation, continuation ownership and active-item event routing are production code.
DECODER = r"""
import AVFoundation
public struct AudioEntryId: Equatable { public init() {} }
public enum AudioPlayerError: Error { case broken }
public enum AudioPlayerState { case ready, playing, running, bufferring, paused, stopped, error, disposed }
public enum AudioPlayerStopReason { case eof, userAction }
public protocol AudioPlayerDelegate: AnyObject {
    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId)
    func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState)
    func audioPlayerDidFinishPlaying(player: AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double)
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError)
}
public struct AudioPlayerConfiguration {
    public init(bufferSizeInSeconds: Double, secondsRequiredToStartPlaying: Double, gracePeriodAfterSeekInSeconds: Double) {}
}
public final class AudioPlayer {
    public static var instances = [AudioPlayer]()
    public weak var delegate: AudioPlayerDelegate?
    public var state = AudioPlayerState.ready, isSeeking = false
    public var progress = 0.0, duration = 180.0, volume: Float = 1, rate: Float = 1
    public var renderingAlgorithm = AVAudio3DMixingRenderingAlgorithm.auto
    public var seeks = [Double](), headers = [String: String]()
    public init(configuration: AudioPlayerConfiguration, outputFormat: AVAudioFormat?) { Self.instances.append(self) }
    public func play(url: URL, headers: [String: String]) { self.headers = headers; state = .bufferring }
    public func seek(to position: Double) { seeks.append(position); isSeeking = true }
    public func pause() { state = .paused }
    public func resume() { if state == .paused { state = .playing } }
    public func stop() { state = .stopped }
}
"""

CHECKS = r"""
import AVFoundation
import AudioStreaming
import Foundation

enum L10n { static func string(_ key: String) -> String { key }; static func format(_ key: String, _ detail: String) -> String { detail } }
enum AVAudioSession { enum InterruptionReason: Sendable { case routeDisconnected } }
enum AudioPlaybackSessionConfigurator { static func activate() throws {} }
struct AudioEqualizerConfiguration {}
struct AudioEqualizerProcessor {
    init(configuration: AudioEqualizerConfiguration) {}
    func attach(to player: AudioPlayer) {}; func update(configuration: AudioEqualizerConfiguration) {}
    func setAutoMixGains(low: Float, mid: Float, high: Float) {}
}
struct PlaybackSource {
    var url = URL(fileURLWithPath: "/fixture"), headers = ["Fixture": "preserved"]
    let preferredForwardBufferDuration = 8.0
}
@MainActor enum AudioPlaybackFormat {
    static var waitForProbe = false, probe: CheckedContinuation<Void, Never>?
    static func load(from: URL, headers: [String: String]) async -> AVAudioFormat? {
        if waitForProbe { await withCheckedContinuation { probe = $0 } }; return nil
    }
}
enum AutoMixFadeCurve { case equalPower, linear, smooth }
struct AutoMixTransitionPlan {
    var duration = 3.0, outgoingStartTime = 170.0, incomingStartTime = 4.0
    var outgoingEndPlaybackRate = 1.0, incomingStartPlaybackRate = 1.0, fadeCurve = AutoMixFadeCurve.linear
}

@MainActor extension AudioPlayer {
    func startSeek() { delegate?.audioPlayerDidStartPlaying(player: self, with: .init()) }
    func decoded(at position: Double = 0.012) {
        state = .playing; isSeeking = false; progress = position
        delegate?.audioPlayerStateChanged(player: self, with: .playing, previous: .bufferring)
    }
}

@main @MainActor struct Checks {
    static func until(_ condition: () -> Bool) async {
        let limit = ContinuousClock.now + .seconds(2)
        while !condition() { precondition(ContinuousClock.now < limit, "event timed out"); await Task.yield() }
    }
    static func loading<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> (Task<T, Never>, AudioPlayer) {
        let count = AudioPlayer.instances.count
        let task = Task { await body() }
        await until { AudioPlayer.instances.count > count }
        return (task, AudioPlayer.instances[count])
    }
    static func check(_ ok: Bool, line: UInt = #line) { precondition(ok, "check failed at line \(line)") }

    static func main() async {
        let engine = AudioPlaybackEngine(equalizerConfiguration: .init()), source = PlaybackSource()
        let (cold, a) = await loading { await engine.load(source, autoplay: true) }
        a.startSeek(); a.decoded(); await cold.value
        a.progress = 179.99; let oldDelegate = a.delegate
        engine.setVolume(0.4)

        var song = "A", events = [String](), ended = 0, failures = 0
        engine.onStateChanged = { events.append("\(song).\($0)") }
        engine.onDurationChanged = { _ in events.append("\(song).duration") }
        engine.onPlaybackClockChanged = { if $0.origin != .periodic { events.append("\(song).\($0.origin)") } }
        engine.onPlaybackEnded = { ended += 1 }; engine.onFailure = { _ in failures += 1 }

        let token = UUID()
        let (prepare, b) = await loading { await engine.prepareStandby(source, token: token) }
        check(b.headers == source.headers && b.volume == 0 && a.volume == 0.4)
        b.decoded() // Merely opening/decoding the source before its initial seek is not ready.
        b.startSeek(); check(b.isSeeking && b.seeks == [0])
        check(!engine.promoteStandby(token: token, autoplay: true))
        b.decoded(); check(await prepare.value)
        engine.cancelAutoMix(); check(!engine.hasPreparedAutoMix)
        check(a.state == .playing && a.progress == 179.99 && b.state == .paused && b.volume == 0)
        check(!engine.promoteStandby(token: UUID(), autoplay: true))
        events.removeAll(); check(engine.promoteStandby(token: token, autoplay: true))
        check(events.isEmpty && engine.state == .playing && b.volume == 0.4 && b.state == .playing)
        check(a.state == .stopped && AudioPlayer.instances.count == 2 && b.seeks == [0])
        song = "B" // Store commit, deliberately after successful promote and before an await.
        b.delegate?.audioPlayerStateChanged(player: b, with: .paused, previous: .playing)
        oldDelegate?.audioPlayerDidFinishPlaying(player: a, entryId: .init(), stopReason: .eof, progress: 180, duration: 180)
        oldDelegate?.audioPlayerUnexpectedError(player: a, error: .broken)
        await until { events.contains("B.activeItemChanged") }
        check(events.contains("B.playing") && !events.contains("B.paused") && ended == 0 && failures == 0)
        check(!engine.promoteStandby(token: token, autoplay: true))

        // Cancel even while AVAsset's format lookup refuses to return. Reusing
        // the token cannot let that stale result touch the newer decoder.
        AudioPlaybackFormat.waitForProbe = true
        let slow = Task { await engine.prepareStandby(source, token: token) }
        await until { AudioPlaybackFormat.probe != nil }
        slow.cancel(); check(await !slow.value)
        AudioPlaybackFormat.waitForProbe = false
        let (pending, superseded) = await loading { await engine.prepareStandby(source, token: token) }
        let supersededDelegate = superseded.delegate, count = AudioPlayer.instances.count
        AudioPlaybackFormat.probe?.resume(); AudioPlaybackFormat.probe = nil
        let (mix, mixed) = await loading { await engine.prepareAutoMix(source, identifier: 3, plan: .init()) }
        check(await !pending.value && AudioPlayer.instances.count == count + 1)
        check(await !engine.prepareStandby(source, token: UUID()))
        supersededDelegate?.audioPlayerUnexpectedError(player: superseded, error: .broken)
        engine.cancelStandby(); mixed.startSeek(); check(mixed.seeks == [4]); mixed.decoded(at: 4.01)
        await mix.value; check(engine.hasPreparedAutoMix && mixed.state == .paused)
        engine.cancelAutoMix(); check(!engine.hasPreparedAutoMix && mixed.state == .stopped && b.state == .playing)

        // A speculative failure (including EOF after ready) cannot advance or
        // fail the active song. A delayed decoder well into the intro is rejected.
        for phase in 0..<3 {
            let (task, player) = await loading { await engine.prepareStandby(source, token: token) }
            player.startSeek()
            switch phase {
            case 0: player.delegate?.audioPlayerUnexpectedError(player: player, error: .broken); check(await !task.value)
            case 1:
                player.decoded(); check(await task.value)
                player.delegate?.audioPlayerDidFinishPlaying(player: player, entryId: .init(), stopReason: .eof, progress: 0.02, duration: 0.02)
            default: player.decoded(at: 3); check(await !task.value)
            }
            check(!engine.promoteStandby(token: token, autoplay: true) && player.state == .stopped)
            check(ended == 0 && failures == 0 && engine.state == .playing && b.volume == 0.4)
        }
        let (pausedPrep, c) = await loading { await engine.prepareStandby(source, token: token) }
        c.startSeek(); c.decoded(); check(await pausedPrep.value)
        engine.pause(); engine.play(); check(c.state == .paused && c.seeks == [0])
        b.state = .stopped
        b.delegate?.audioPlayerDidFinishPlaying(player: b, entryId: .init(), stopReason: .eof, progress: 180, duration: 180)
        check(ended == 1 && engine.currentPlaybackTime == 180 && c.state == .paused && c.volume == 0)
        engine.cancelAutoMix(); check(b.state == .stopped && b.seeks == [0]); events.removeAll()
        check(engine.promoteStandby(token: token, autoplay: false) && events.isEmpty && c.state == .paused)
        engine.cancelStandby(); check(c.state == .paused && !engine.expectsPlaybackToContinue)
        engine.unload(); events.removeAll(); await Task.yield()
        check(!events.contains("B.activeItemChanged")) // Deferred delivery cannot revive an unloaded generation.

        // A running fade still owns both decks. Its EOF consumes the fade,
        // not another queue slot, even if AutoMix is disabled during completion.
        let (again, outgoing) = await loading { await engine.load(source, autoplay: true) }
        outgoing.startSeek(); outgoing.decoded(); await again.value; outgoing.progress = 176
        var completed = 0
        engine.onAutoMixTransitionCompleted = { _ in completed += 1; engine.cancelAutoMix() }
        let (fade, incoming) = await loading { await engine.prepareAutoMix(source, identifier: 4, plan: .init()) }
        incoming.startSeek(); incoming.decoded(at: 4.01); await fade.value
        check(incoming.state == .playing && engine.hasPreparedAutoMix)
        check(await !engine.prepareStandby(source, token: token))
        outgoing.state = .stopped
        outgoing.delegate?.audioPlayerDidFinishPlaying(player: outgoing, entryId: .init(), stopReason: .eof, progress: 180, duration: 180)
        check(completed == 1 && ended == 1 && incoming.state == .playing && incoming.volume == 0.4)
        engine.unload()

        let deck = AudioPlaybackDeck(equalizerConfiguration: .init())
        check(await !deck.load(source, timeout: .milliseconds(10))) // A completely silent decoder.
        check(!deck.hasCurrentItem && deck.state == .idle)
        print("PASS: muted seek + pause; playing/paused promotion; late events; cancellation/timeout; standby/AutoMix ownership")
    }
}
"""


class StandbyEngineTests(unittest.TestCase):
    def test_dual_deck_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "Decoder.swift").write_text(DECODER)
            (temp / "Checks.swift").write_text(CHECKS)
            engine = (PLAYBACK / "Engine/AudioPlaybackEngine.swift").read_text()
            # Drop only iOS session notification plumbing and the unused macOS spatial-audio branch.
            engine = engine[:engine.index("    private func installAudioSessionObservers(")] + "}\n"
            (temp / "Engine.swift").write_text(engine.replace("#if os(macOS)", "#if DESKTOP_APP"))
            swift = ["xcrun", "--sdk", "macosx", "swiftc"]
            subprocess.run([*swift, "-emit-module", "-emit-library", "-module-name", "AudioStreaming",
                            "Decoder.swift", "-o", "libAudioStreaming.dylib"], cwd=temp, check=True)
            sources = [PLAYBACK / "Engine/AudioPlaybackDeck.swift", PLAYBACK / "Engine/AudioPlaybackClockSample.swift",
                       *[PLAYBACK / f"AutoMix/{name}.swift" for name in ("AutoMixDeckTransitionController",
                         "AutoMixTempoEnvelope", "AutoMixFadeEnvelope", "AutoMixEqualizerEnvelope")]]
            subprocess.run([*swift, "-parse-as-library", "-I", ".", "-L", ".", "-lAudioStreaming", "-Xlinker", "-rpath",
                            "-Xlinker", str(temp), "Engine.swift", "Checks.swift", *sources, "-o", "check"], cwd=temp, check=True)
            subprocess.run([str(temp / "check")], cwd=temp, check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
