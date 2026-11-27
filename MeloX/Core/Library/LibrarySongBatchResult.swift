import Foundation

nonisolated struct LibrarySongBatchResult: Sendable {
    struct Failure: Sendable {
        let songID: Int
        let message: String
    }

    let succeededSongIDs: [Int]
    let failures: [Failure]

    var failedSongIDs: Set<Int> { Set(failures.map(\.songID)) }
    var isComplete: Bool { failures.isEmpty }

    var errorMessage: String? {
        guard let first = failures.first else { return nil }
        return L10n.format(
            "ui.library.edit.partial_failure",
            succeededSongIDs.count,
            failedSongIDs.count,
            first.message
        )
    }
}
