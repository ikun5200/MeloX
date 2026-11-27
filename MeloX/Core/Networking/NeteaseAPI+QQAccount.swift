import Foundation

extension NeteaseAPI {
    func withQQAccountRead<Value>(
        _ operation: @MainActor (QQMusicClient) async throws -> Value
    ) async throws -> Value {
        try await qqAccountReads.read(
            currentCredential: { settings.qqCredential },
            refresh: { [qqLoginService] in try await qqLoginService.refresh($0) },
            saveCredential: { acceptRenewedQQCredential($0) },
            operation: { credential in
                try await operation(qq.replacingCredential(credential))
            }
        )
    }

    func renewQQAccount() async throws {
        _ = try await qqAccountReads.renew(
            currentCredential: { settings.qqCredential },
            refresh: { [qqLoginService] in try await qqLoginService.refresh($0) },
            saveCredential: { acceptRenewedQQCredential($0) }
        )
    }
}
