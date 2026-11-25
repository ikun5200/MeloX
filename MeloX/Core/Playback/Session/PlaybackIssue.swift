import Foundation

/// A song that could not be played, as told to the listener.
///
/// It is shown as a passing notice, never a dialog: playback moves on by
/// itself, and a dialog raised from under the player took the player down
/// with it.
struct PlaybackIssue: Identifiable, Sendable {
    let id = UUID()
    let songID: Int
    let message: String
    /// False when skipping ahead would meet the same failure, as it would
    /// with no network.
    let offersNextSong: Bool

    init(song: Song, error: Error) {
        songID = song.id
        offersNextSong = true

        if let apiError = error as? APIError,
           case .noPlayableSource = apiError {
            message = L10n.format("ui.error.playback.unavailable", song.name)
            return
        }

        if let sourceError = error as? LXPlaybackError {
            switch sourceError {
            case .noSource:
                message = L10n.string("ui.error.playback.no_source_enabled")
            case .missingSongMID, .invalidURL, .noSourceResolved,
                 .unplayableStream, .trialClip:
                message = L10n.format(
                    "ui.error.playback.no_stream",
                    song.name
                )
            }
            return
        }

        if let playbackError = error as? AudioPlaybackError,
           case .itemFailed = playbackError {
            message = L10n.format("ui.error.playback.source_load_failed", song.name)
            return
        }

        message = L10n.format("ui.error.playback.failed", song.name, error.localizedDescription)
    }

    /// The device has no connection, so no song can be fetched.
    init(offlineFor song: Song) {
        songID = song.id
        offersNextSong = false
        message = L10n.string("ui.error.playback.offline")
    }
}
