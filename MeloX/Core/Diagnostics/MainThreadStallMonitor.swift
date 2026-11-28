import Foundation

/// Simulator-rig diagnostics: reports how long the main queue went without
/// running its heartbeat, so playback stutter can be correlated with
/// main-thread blocking. Compiled out of every build but the simulator's
/// debug build. See `Tools/Tests/sim_rig`.
enum MainThreadStallMonitor {
    private static let lock = NSLock()
    private static var lastHeartbeat = CFAbsoluteTimeGetCurrent()

    static func start() {
        #if DEBUG && targetEnvironment(simulator)
        installHeartbeat()
        installWatchdog()
        #endif
    }

    private static func installHeartbeat() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        source.schedule(deadline: .now(), repeating: .milliseconds(100))
        source.setEventHandler {
            lock.withLock { lastHeartbeat = CFAbsoluteTimeGetCurrent() }
        }
        source.resume()
        // The source intentionally lives for the process lifetime.
        heartbeatSource = source
    }

    private static var heartbeatSource: DispatchSourceTimer?

    private static func installWatchdog() {
        DispatchQueue(label: "melox.stall.watchdog", qos: .userInitiated).async {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                let beat = lock.withLock { lastHeartbeat }
                let lagSeconds = now - beat
                if lagSeconds > 0.25 {
                    rigTrace("stall", "main queue lag \(Int(lagSeconds * 1_000))ms")
                }
            }
        }
    }
}
