"""Offline checks for QQ account reads; --baseline records the old error path."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "MeloX/Core/Backend/QQ/QQMusicClient.swift",
    "MeloX/Core/Backend/QQ/QQCredential.swift",
    "MeloX/Core/Backend/QQ/QQMusicError.swift",
    "MeloX/Core/Backend/QQ/QQLoginService.swift",
    "MeloX/Core/Backend/QQ/QQAccountReadCoordinator.swift",
    "MeloX/Core/Backend/QQ/QQMusicSearchModels.swift",
    "MeloX/Core/Backend/QQ/QQMusicDetailModels.swift",
    "MeloX/Core/Backend/QQ/QQMusicCommentModels.swift",
    "MeloX/Core/Backend/QQ/QQMusicMVModels.swift",
    "MeloX/Core/Models/Music/SongAudioAvailability.swift",
    "MeloX/Core/Settings/Playback/MusicQuality.swift",
]
STUBS = r'''
import Foundation

nonisolated enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ values: CVarArg...) -> String { key }
    static func joined(_ values: [String], separatorKey: String) -> String { values.joined(separator: ", ") }
}

final class AccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var rootFailure = false
    private var count = 0
    func configure(root: Bool) { lock.withLock { rootFailure = root; count = 0 } }
    func response() -> Data {
        lock.withLock {
            count += 1
            let json: [String: Any] = rootFailure
                ? ["code": 1000]
                : ["code": 0, "req_0": ["code": 1000, "data": [:]]]
            return try! JSONSerialization.data(withJSONObject: json)
        }
    }
    var requests: Int { lock.withLock { count } }
}

final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = AccountFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.fixture.response())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func fixtureClient() -> QQMusicClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountURLProtocol.self]
    let credential = QQCredential(musicID: 123, musicKey: "fixture-key", encryptUIN: "fixture-euin")
    return QQMusicClient(session: URLSession(configuration: configuration), credential: credential)
}
'''
BASELINE = r'''
@main struct Harness {
    static func main() async throws {
        for root in [false, true] {
            AccountURLProtocol.fixture.configure(root: root)
            do {
                _ = try await fixtureClient().followedArtists()
                preconditionFailure("expected code 1000")
            } catch QQMusicError.server(let code, _) {
                precondition(code == 1000)
                precondition(AccountURLProtocol.fixture.requests == 1)
                print(root ? "baseline root1000: generic server error" : "baseline module1000: generic server error")
            }
        }
    }
}
'''
HARNESS = r'''
import Foundation

@MainActor final class CredentialBox {
    var credential = QQCredential(musicID: 123, musicKey: "old-key", refreshKey: "fixture-refresh", refreshToken: "fixture-token", encryptUIN: "fixture-euin")
    var refreshes = 0
    var reads = 0
    func refresh(_ old: QQCredential) async throws -> QQCredential {
        refreshes += 1
        try await Task.sleep(for: .milliseconds(20))
        var updated = old
        updated.musicKey = "new-key"
        updated.expiredAt = 0
        return updated
    }
    func read(_ sent: QQCredential) throws -> Int {
        reads += 1
        if sent.musicKey == "old-key" { throw QQMusicError.credentialExpired(code: 1000) }
        return 7
    }
}

@main @MainActor struct Harness {
    static func main() async throws {
        for root in [false, true] {
            AccountURLProtocol.fixture.configure(root: root)
            do {
                _ = try await fixtureClient().followedArtists()
                preconditionFailure("expected authentication failure")
            } catch let error as QQMusicError {
                precondition(error.isAuthenticationFailure)
                precondition(AccountURLProtocol.fixture.requests == 1)
            }
        }
        let credential = QQCredential(musicID: 123, musicKey: "old-key")
        var renewed = credential
        renewed.musicKey = "new-key"
        precondition(credential.accountScopeID == renewed.accountScopeID)
        precondition(!QQMusicError.server(code: 500, message: nil).isAuthenticationFailure)
        precondition(QQMusicError.server(code: 2001, message: nil).isRateLimited)
        precondition(!QQMusicError.accessDenied(code: 403).isAuthenticationFailure)
        var timed = credential
        timed.expiredAt = 1_760_000_000_000
        precondition(timed.isExpired(at: Date(timeIntervalSince1970: 1_760_000_001)))

        let shared = QQAccountReadCoordinator()
        let box = CredentialBox()
        async let a = shared.read(currentCredential: { box.credential }, refresh: { try await box.refresh($0) }, saveCredential: { box.credential = $0 }, operation: { try box.read($0) })
        async let b = shared.read(currentCredential: { box.credential }, refresh: { try await box.refresh($0) }, saveCredential: { box.credential = $0 }, operation: { try box.read($0) })
        let values = try await (a, b)
        precondition(values.0 == 7 && values.1 == 7)
        precondition(box.refreshes == 1 && box.reads == 4)
        precondition(!shared.requiresRelogin)

        let proactive = QQAccountReadCoordinator()
        let expired = CredentialBox()
        expired.credential.expiredAt = 1
        let value = try await proactive.read(currentCredential: { expired.credential }, refresh: { try await expired.refresh($0) }, saveCredential: { expired.credential = $0 }, operation: { try expired.read($0) })
        precondition(value == 7 && expired.refreshes == 1 && expired.reads == 1)

        let missing = QQAccountReadCoordinator()
        let noRefresh = CredentialBox()
        noRefresh.credential.refreshKey = ""
        let saved = noRefresh.credential
        do {
            _ = try await missing.read(currentCredential: { noRefresh.credential }, refresh: { try await noRefresh.refresh($0) }, saveCredential: { noRefresh.credential = $0 }, operation: { try noRefresh.read($0) })
            preconditionFailure("missing refresh should fail")
        } catch let error as QQMusicError { precondition(error.isAuthenticationFailure) }
        precondition(missing.requiresRelogin && noRefresh.credential == saved && noRefresh.refreshes == 0)

        let refused = QQAccountReadCoordinator()
        let refusedBox = CredentialBox()
        do {
            _ = try await refused.read(currentCredential: { refusedBox.credential }, refresh: { try await refusedBox.refresh($0) }, saveCredential: { refusedBox.credential = $0 }, operation: { _ -> Int in
                refusedBox.reads += 1
                throw QQMusicError.credentialExpired(code: 1000)
            })
            preconditionFailure("second refusal should fail")
        } catch let error as QQMusicError { precondition(error.isAuthenticationFailure) }
        precondition(refused.requiresRelogin && refusedBox.refreshes == 1 && refusedBox.reads == 2)
        precondition(refusedBox.credential.musicKey == "new-key")

        let offline = QQAccountReadCoordinator()
        let offlineBox = CredentialBox()
        let beforeOffline = offlineBox.credential
        do {
            _ = try await offline.read(currentCredential: { offlineBox.credential }, refresh: { _ in
                offlineBox.refreshes += 1
                throw URLError(.timedOut)
            }, saveCredential: { offlineBox.credential = $0 }, operation: { try offlineBox.read($0) })
            preconditionFailure("offline renewal should fail")
        } catch QQMusicError.transport { }
        precondition(!offline.requiresRelogin && offlineBox.credential == beforeOffline && offlineBox.refreshes == 1)

        let switched = QQAccountReadCoordinator()
        let switchedBox = CredentialBox()
        let pending = Task { @MainActor in
            try await switched.read(currentCredential: { switchedBox.credential }, refresh: { try await switchedBox.refresh($0) }, saveCredential: { switchedBox.credential = $0 }, operation: { try switchedBox.read($0) })
        }
        try await Task.sleep(for: .milliseconds(5))
        switchedBox.credential = QQCredential(musicID: 456, musicKey: "other-account")
        switched.sessionDidChange()
        do { _ = try await pending.value; preconditionFailure("stale renewal should cancel") }
        catch is CancellationError { }
        precondition(switchedBox.credential.musicID == 456 && switchedBox.credential.musicKey == "other-account")

        print("QQ account error mapping, shared renewal, retry bound, expiry, missing refresh, timeout, and account switch checks passed")
    }
}
'''


def run_harness(body):
    with tempfile.TemporaryDirectory(prefix="melox-qq-account-") as directory:
        directory = Path(directory)
        stub = directory / "Stubs.swift"
        main = directory / "Harness.swift"
        executable = directory / "checks"
        stub.write_text(STUBS)
        main.write_text(body)
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *[str(ROOT / p) for p in SOURCES], str(stub), str(main), "-o", str(executable)], check=True, cwd=ROOT)
        subprocess.run([str(executable)], check=True, cwd=ROOT, timeout=30)


class QQAccountChecks(unittest.TestCase):
    def test_account_errors(self):
        run_harness(HARNESS)


if __name__ == "__main__":
    if "--baseline" in sys.argv:
        run_harness(BASELINE)
    else:
        unittest.main()
