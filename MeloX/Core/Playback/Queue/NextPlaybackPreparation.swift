import Foundation

/// Inputs that can change source selection without changing the queue.
struct PlaybackSelectionPolicy: Equatable {
    let quality: MusicQuality
    let hasSessionQuality: Bool
    let isCellular: Bool
    let isOnline: Bool
    let sourceRevision: UInt64
    // Re-installing a download can reuse the exact same file URL.
    let downloadedAt: Date?
}

struct SelectedPlaybackSource: Sendable {
    let source: PlaybackSource
    let isDownloaded: Bool
    private let selectedAt = ContinuousClock.now

    var isFresh: Bool {
        isDownloaded || selectedAt.duration(to: .now) < .seconds(180)
    }
}

/// One owner of the resolution and, in ordinary mode only, the standby deck.
/// The foreground can take the resolution without taking an unfinished deck.
@MainActor
final class NextPlaybackPreparation {
    enum Phase: String { case resolving, resolved, buffering, ready, failed }

    struct Key: Equatable {
        let loadGeneration: Int
        let queueRevision: Int
        let outgoingIndex: Int
        let outgoingID: Int
        let incomingIndex: Int
        let incomingID: Int
        let repeatMode: RepeatMode
        let autoMixEnabled: Bool
        let policy: PlaybackSelectionPolicy
    }

    let token = UUID()
    let key: Key
    let resolution: Task<SelectedPlaybackSource, Error>
    var warmingTask: Task<Void, Never>?
    var selected: SelectedPlaybackSource?
    var phase: Phase = .resolving {
        didSet { if phase == .failed { failedAt = .now } }
    }
    private var failedAt: ContinuousClock.Instant?

    var isFresh: Bool {
        if let failedAt { return failedAt.duration(to: .now) < .seconds(60) }
        return selected?.isFresh != false
    }

    init(key: Key, resolution: Task<SelectedPlaybackSource, Error>) {
        self.key = key
        self.resolution = resolution
    }
}
