import Foundation

nonisolated enum QQMusicError: LocalizedError, Sendable {
    case invalidResponse
    case server(code: Int, message: String?)
    case transport(code: Int)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.string("ui.error.api.invalid_response")
        case .server(let code, _):
            L10n.format("ui.error.api.server_code", code)
        case .transport:
            L10n.string("ui.error.api.invalid_response")
        case .notLoggedIn:
            L10n.string("ui.error.api.login_required")
        }
    }
}
