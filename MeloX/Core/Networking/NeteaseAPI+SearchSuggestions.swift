import Foundation

extension NeteaseAPI {
    func searchSuggestions(_ keywords: String) async throws -> [String] {
        try await qq.searchSuggestions(keywords)
    }
}
