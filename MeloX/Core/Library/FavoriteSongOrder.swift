import Foundation

nonisolated struct FavoriteSongOrder: Codable, Equatable, Sendable {
    private(set) var songIDs: [Int]

    init(songIDs: [Int]) {
        self.songIDs = Self.uniqueIDs(songIDs)
    }

    func applying(to availableIDs: [Int]) -> [Int] {
        let available = Self.uniqueIDs(availableIDs)
        let availableSet = Set(available)
        let savedSet = Set(songIDs)
        return available.filter { !savedSet.contains($0) }
            + songIDs.filter { availableSet.contains($0) }
    }

    /// A partial page cannot prove that a saved song has been removed.
    func reconciled(with remoteIDs: [Int], isComplete: Bool) -> Self {
        let remote = Self.uniqueIDs(remoteIDs)
        let remoteSet = Set(remote)
        let savedSet = Set(songIDs)
        let newIDs = remote.filter { !savedSet.contains($0) }
        let retained = songIDs.filter { !isComplete || remoteSet.contains($0) }
        return Self(songIDs: newIDs + retained)
    }

    func adding(_ songID: Int) -> Self {
        Self(songIDs: [songID] + songIDs.filter { $0 != songID })
    }

    func removing(_ songID: Int) -> Self {
        Self(songIDs: songIDs.filter { $0 != songID })
    }

    func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> Self {
        let indices = source.filter { songIDs.indices.contains($0) }
        guard !indices.isEmpty else { return self }
        let movedIDs = indices.map { songIDs[$0] }
        let sourceSet = Set(indices)
        var remaining = songIDs.enumerated().compactMap {
            sourceSet.contains($0.offset) ? nil : $0.element
        }
        let removedBeforeDestination = indices.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBeforeDestination, 0), remaining.count)
        remaining.insert(contentsOf: movedIDs, at: insertion)
        return Self(songIDs: remaining)
    }

    static func uniqueIDs(_ songIDs: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return songIDs.filter { $0 > 0 && seen.insert($0).inserted }
    }
}
