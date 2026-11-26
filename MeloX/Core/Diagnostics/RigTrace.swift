import Foundation

/// A line in the simulator rig's log, for following what playback did.
///
/// Written to standard error, so that the lines before a crash are not lost
/// in a buffer. Compiled out of every build but the simulator's debug
/// build. Addresses must not be traced: a source's address carries its key.
/// See `Tools/Tests/sim_rig`.
@inline(__always)
nonisolated func rigTrace(
    _ scope: String,
    _ message: @autoclosure () -> String
) {
    #if DEBUG && targetEnvironment(simulator)
    let time = Date().formatted(
        .dateTime.hour().minute().second().secondFraction(.fractional(2))
    )
    FileHandle.standardError.write(
        Data("[\(scope)] \(time) \(message())\n".utf8)
    )
    #endif
}
