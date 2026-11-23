import Foundation
import Observation
import UIKit

/// Routes URLs opened from the app's Live Activity or other deep links.
///
/// SwiftUI's `onOpenURL` normally delivers these, but a Live Activity tap
/// can launch the app before the root view has installed its handler.
/// The app delegate forwards the same URL here so `ContentView` can pick
/// it up after playback state has been restored.
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private(set) var nowPlayingRequestCount = 0

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "melox" else { return }
        let host = url.host?.lowercased()
        let path = url.path
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()
        guard host == "now-playing" || path == "now-playing" else {
            return
        }
        nowPlayingRequestCount += 1
    }

    /// The system uses this path when a Live Activity is tapped but does
    /// not provide a URL.
    func handleLiveActivityContinuation() {
        nowPlayingRequestCount += 1
    }
}

final class MeloXAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task { @MainActor in
            DeepLinkRouter.shared.handle(url)
        }
        return true
    }
}
