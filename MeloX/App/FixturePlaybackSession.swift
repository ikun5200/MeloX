#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// Used only by the local playback acceptance rig. No account refresh, lyrics,
/// recommendations or restored queue should participate in a fixture run.
nonisolated enum FixturePlaybackSession {
    static let isEnabled: Bool = {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-MeloXFixtureOnly"),
              args.indices.contains(flag + 1) else { return false }
        return args[flag + 1] == "YES"
    }()

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.protocolClasses = [DenyRemoteFixtureRequest.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config, delegate: FixtureRedirects(), delegateQueue: nil)
    }()
}

private nonisolated final class DenyRemoteFixtureRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { !FixturePlaybackSession.allows(request.url) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private nonisolated final class FixtureRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(FixturePlaybackSession.allows(request.url) ? request : nil)
    }
}

struct FixturePlaybackControls: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        VStack {
            if let song = player.currentSong {
                Text(verbatim: song.name)
                NowPlayingQualityMenu()
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
