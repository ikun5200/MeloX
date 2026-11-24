import Foundation

nonisolated struct PlaybackSnapshot: Codable, Sendable {
    let queue: [Song]
    let currentIndex: Int
    let progress: TimeInterval
    let repeatMode: String
    let isShuffled: Bool
    let shuffledOrder: [Int]
    let volume: Double
    let historySourceID: Int?
    let heartModeEnabled: Bool?
    let autoplayEnabled: Bool?
    let autoMixEnabled: Bool?
    let queueModeIndicator: String?

    func withProgress(_ progress: TimeInterval) -> PlaybackSnapshot {
        PlaybackSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            progress: progress,
            repeatMode: repeatMode,
            isShuffled: isShuffled,
            shuffledOrder: shuffledOrder,
            volume: volume,
            historySourceID: historySourceID,
            heartModeEnabled: heartModeEnabled,
            autoplayEnabled: autoplayEnabled,
            autoMixEnabled: autoMixEnabled,
            queueModeIndicator: queueModeIndicator
        )
    }
}

@MainActor
final class PlaybackPersistence {
    private enum Key {
        static let snapshot = "player.playbackSnapshot.v2"
        static let progress = "player.playbackSnapshot.v2.progress"
    }

    private let defaults: UserDefaults
    /// Encoding a long queue takes several milliseconds, more than a
    /// 120Hz frame, so it never runs on the main thread. The queue is
    /// serial to keep saves and clears in the order they were issued.
    private let writeQueue = DispatchQueue(
        label: "melox.playback-persistence",
        qos: .utility
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PlaybackSnapshot? {
        guard let data = defaults.data(forKey: Key.snapshot),
              let snapshot = try? JSONDecoder().decode(
                PlaybackSnapshot.self,
                from: data
              ) else {
            return nil
        }
        guard let progress = defaults.object(forKey: Key.progress)
                as? TimeInterval else {
            return snapshot
        }
        return snapshot.withProgress(progress)
    }

    func save(_ snapshot: PlaybackSnapshot) {
        let defaults = defaults
        let snapshotKey = Key.snapshot
        defaults.set(snapshot.progress, forKey: Key.progress)
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else {
                return
            }
            defaults.set(data, forKey: snapshotKey)
        }
    }

    /// The position changes every second during playback while the queue
    /// does not, so it is stored on its own instead of re-encoding the
    /// whole snapshot.
    func saveProgress(_ progress: TimeInterval) {
        defaults.set(progress, forKey: Key.progress)
    }

    func clear() {
        let defaults = defaults
        let snapshotKey = Key.snapshot
        defaults.removeObject(forKey: Key.progress)
        writeQueue.async {
            defaults.removeObject(forKey: snapshotKey)
        }
    }
}
