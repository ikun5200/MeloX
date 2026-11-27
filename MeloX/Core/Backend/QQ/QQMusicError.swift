import Foundation

nonisolated enum QQMusicError: LocalizedError, Sendable {
    case invalidResponse
    case server(code: Int, message: String?)
    case transport(code: Int)
    case httpStatus(code: Int)
    case notLoggedIn
    case credentialExpired(code: Int)
    case incompleteCredential
    case accessDenied(code: Int)

    static func response(code: Int, message: String? = nil) -> Self {
        switch code {
        case 1000, 104400, 104401:
            .credentialExpired(code: code)
        case 401:
            .credentialExpired(code: code)
        case 403:
            .accessDenied(code: code)
        default:
            .server(code: code, message: message)
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .notLoggedIn, .credentialExpired, .incompleteCredential:
            true
        case .server(let code, _):
            [1000, 104400, 104401, 401].contains(code)
        case .httpStatus(let code):
            code == 401
        default:
            false
        }
    }

    var isRateLimited: Bool {
        switch self {
        case .server(let code, _): code == 2001 || code == 429
        case .httpStatus(let code): code == 429
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.string("ui.error.api.invalid_response")
        case .server(let code, _):
            isAuthenticationFailure
                ? L10n.string("ui.error.qq.login_expired")
                : L10n.format("ui.error.api.server_code", code)
        case .transport:
            L10n.string("ui.error.qq.network")
        case .httpStatus(let code):
            isAuthenticationFailure
                ? L10n.string("ui.error.qq.login_expired")
                : L10n.format("ui.error.api.server_code", code)
        case .notLoggedIn:
            L10n.string("ui.error.api.login_required")
        case .credentialExpired:
            L10n.string("ui.error.qq.login_expired")
        case .incompleteCredential:
            L10n.string("ui.error.qq.incomplete_credential")
        case .accessDenied:
            L10n.string("ui.error.qq.access_denied")
        }
    }
}
