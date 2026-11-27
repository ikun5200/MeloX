import Foundation

struct MusicCollectionSelection: Equatable {
    private(set) var isSelecting = false
    private(set) var selectedSongIDs: Set<Int> = []

    mutating func beginSelection() {
        selectedSongIDs.removeAll()
        isSelecting = true
    }

    mutating func finishSelection() {
        selectedSongIDs.removeAll()
        isSelecting = false
    }

    mutating func toggleSelection(songID: Int) {
        guard songID > 0 else { return }
        if selectedSongIDs.contains(songID) {
            selectedSongIDs.remove(songID)
        } else {
            selectedSongIDs.insert(songID)
        }
    }

    mutating func toggleAll(songIDs: Set<Int>) {
        let validIDs = songIDs.filter { $0 > 0 }
        guard !validIDs.isEmpty else { return }
        if validIDs.isSubset(of: selectedSongIDs) {
            selectedSongIDs.subtract(validIDs)
        } else {
            selectedSongIDs.formUnion(validIDs)
        }
    }

    mutating func retainSelection(in songIDs: Set<Int>) {
        selectedSongIDs.formIntersection(songIDs)
    }

    mutating func removeSelection(_ songIDs: Set<Int>) {
        selectedSongIDs.subtract(songIDs)
    }

    func orderedIDs(in songIDs: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return songIDs.filter { selectedSongIDs.contains($0) && seen.insert($0).inserted }
    }
}
