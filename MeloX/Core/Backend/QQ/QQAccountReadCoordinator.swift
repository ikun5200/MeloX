import Foundation
import Observation

@MainActor
@Observable
final class QQAccountReadCoordinator {
    private struct Renewal {
        let id: UUID
        let credential: QQCredential
        let task: Task<QQCredential, Error>
    }

    private(set) var requiresRelogin = false
    @ObservationIgnored private var renewal: Renewal?
    @ObservationIgnored private var generation: UInt64 = 0

    func sessionDidChange() {
        generation &+= 1
        renewal?.task.cancel()
        renewal = nil
        requiresRelogin = false
    }

    /// Only idempotent reads belong here. Writes must not be replayed when
    /// a response was lost after the service may already have accepted them.
    func read<Value>(
        currentCredential: @MainActor () -> QQCredential,
        refresh: @escaping @MainActor (QQCredential) async throws -> QQCredential,
        saveCredential: @MainActor (QQCredential) -> Void,
        operation: @MainActor (QQCredential) async throws -> Value
    ) async throws -> Value {
        let original = currentCredential()
        guard original.isValid else { throw QQMusicError.notLoggedIn }
        guard !requiresRelogin else { throw QQMusicError.credentialExpired(code: 1000) }
        let readGeneration = generation
        var credential = original
        if credential.isExpired {
            credential = try await renew(
                expected: credential,
                currentCredential: currentCredential,
                refresh: refresh,
                saveCredential: saveCredential
            )
        }
        do {
            let value = try await operation(credential)
            try check(original, generation: readGeneration, current: currentCredential())
            return value
        } catch let error as QQMusicError where error.isAuthenticationFailure {
            try check(original, generation: readGeneration, current: currentCredential())
            credential = try await renew(
                expected: credential,
                currentCredential: currentCredential,
                refresh: refresh,
                saveCredential: saveCredential
            )
            // One retry, not a loop. A second refusal requires user action.
            do {
                let value = try await operation(credential)
                try check(original, generation: readGeneration, current: currentCredential())
                return value
            } catch let retryError as QQMusicError where retryError.isAuthenticationFailure {
                try check(original, generation: readGeneration, current: currentCredential())
                requiresRelogin = true
                throw retryError
            }
        }
    }

    func renew(
        expected: QQCredential? = nil,
        currentCredential: @MainActor () -> QQCredential,
        refresh: @escaping @MainActor (QQCredential) async throws -> QQCredential,
        saveCredential: @MainActor (QQCredential) -> Void
    ) async throws -> QQCredential {
        let original = expected ?? currentCredential()
        guard original.isValid else { throw QQMusicError.notLoggedIn }
        let renewalGeneration = generation
        try check(original, generation: renewalGeneration, current: currentCredential())
        if currentCredential() != original {
            return currentCredential()
        }
        guard !original.refreshKey.isEmpty, !original.refreshToken.isEmpty else {
            requiresRelogin = true
            throw QQMusicError.credentialExpired(code: 1000)
        }

        let active: Renewal
        if let renewal, renewal.credential == original {
            active = renewal
        } else {
            let task = Task { try await refresh(original) }
            active = Renewal(id: UUID(), credential: original, task: task)
            renewal = active
        }
        defer {
            if renewal?.id == active.id { renewal = nil }
        }
        do {
            let updated = try await active.task.value
            try check(original, generation: renewalGeneration, current: currentCredential())
            guard updated.isValid, updated.musicID == original.musicID else {
                requiresRelogin = true
                throw QQMusicError.incompleteCredential
            }
            if currentCredential() == original { saveCredential(updated) }
            requiresRelogin = false
            return currentCredential()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QQMusicError {
            try check(original, generation: renewalGeneration, current: currentCredential())
            if error.isAuthenticationFailure { requiresRelogin = true }
            throw error
        } catch let error as QQLoginError {
            try check(original, generation: renewalGeneration, current: currentCredential())
            switch error {
            case .missingCredential, .captchaRequired:
                requiresRelogin = true
                throw QQMusicError.credentialExpired(code: 1000)
            case .loginFailed(let code, _):
                let error = QQMusicError.response(code: code)
                if error.isAuthenticationFailure { requiresRelogin = true }
                throw error
            default:
                throw QQMusicError.invalidResponse
            }
        } catch {
            try check(original, generation: renewalGeneration, current: currentCredential())
            throw QQMusicError.transport(code: (error as? URLError)?.errorCode ?? -1)
        }
    }

    private func check(_ original: QQCredential, generation expectedGeneration: UInt64, current: QQCredential) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration,
              current.isValid,
              current.musicID == original.musicID else { throw CancellationError() }
    }
}
