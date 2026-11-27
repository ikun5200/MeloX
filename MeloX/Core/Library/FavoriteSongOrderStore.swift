import CryptoKit
import Foundation

nonisolated struct FavoriteSongOrderStore: Sendable {
    private struct Record: Codable {
        let version: Int
        let order: FavoriteSongOrder
    }

    let directory: URL

    init(directory: URL = AppStorageLocations.applicationSupportRoot()
        .appending(path: "FavoriteSongOrder", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(accountScope: String) throws -> FavoriteSongOrder? {
        let url = try fileURL(accountScope: accountScope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw FavoriteSongOrderError.invalidRecord }
        return FavoriteSongOrder(songIDs: record.order.songIDs)
    }

    func save(_ order: FavoriteSongOrder, accountScope: String) throws {
        let url = try fileURL(accountScope: accountScope)
        let data = try JSONEncoder().encode(Record(version: 1, order: order))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func fileURL(accountScope: String) throws -> URL {
        guard !accountScope.isEmpty else { throw FavoriteSongOrderError.noAccount }
        let digest = SHA256.hash(data: Data(accountScope.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}

nonisolated enum FavoriteSongOrderError: LocalizedError {
    case noAccount
    case invalidRecord
    case incompleteLibrary

    var errorDescription: String? {
        switch self {
        case .noAccount:
            L10n.string("ui.error.api.login_required")
        case .invalidRecord:
            L10n.string("ui.library.edit.order_read_failed")
        case .incompleteLibrary:
            L10n.string("ui.library.edit.order_requires_complete_list")
        }
    }
}
