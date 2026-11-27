import SwiftUI

struct QQAccountSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NeteaseAPI.self) private var api
    @Environment(LibraryStore.self) private var library

    @State private var showsLogin = false
    @State private var isRenewing = false
    @State private var didRenew = false
    @State private var renewalError: String?

    var body: some View {
        List {
            Section {
                if settings.isQQLoggedIn {
                    HStack {
                        Text("ui.settings.qq_account.music_id")
                        Spacer()
                        Text(verbatim: String(settings.qqCredential.musicID))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("ui.settings.qq_account.login_type")
                        Spacer()
                        Text(settings.qqCredential.loginType == 1
                            ? L10n.string("ui.settings.qq_account.login_type.wechat")
                            : L10n.string("ui.settings.qq_account.login_type.qq"))
                            .foregroundStyle(.secondary)
                    }
                    if api.requiresQQRelogin {
                        Label("ui.error.qq.login_expired", systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        renewSession()
                    } label: {
                        HStack {
                            Text(didRenew ? L10n.string("ui.qq_account.renewed") : L10n.string("ui.qq_account.renew"))
                            Spacer()
                            if isRenewing { ProgressView() }
                        }
                    }
                    .disabled(isRenewing)
                    .accessibilityIdentifier("qq-account-renew")
                    Button("ui.qq_account.login_again") { showsLogin = true }
                        .disabled(isRenewing)
                    Button("ui.qq_account.logout", role: .destructive) {
                        api.clearAccount()
                        library.clearAccountData()
                    }
                    .disabled(isRenewing)
                } else {
                    Button("ui.qq_account.login") { showsLogin = true }
                }
            } footer: {
                Text("ui.settings.qq_account.footer")
            }
        }
        .navigationTitle("ui.settings.qq_account.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsLogin) { QQLoginView() }
        .alert("ui.qq_account.renew_failed", isPresented: Binding(
            get: { renewalError != nil },
            set: { if !$0 { renewalError = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) { renewalError = nil }
        } message: {
            Text(renewalError ?? "")
        }
    }

    private func renewSession() {
        guard !isRenewing else { return }
        isRenewing = true
        didRenew = false
        Task { @MainActor in
            defer { isRenewing = false }
            do {
                try await api.renewQQAccount()
                await library.refresh(force: true)
                didRenew = true
            } catch is CancellationError {
                return
            } catch {
                renewalError = error.localizedDescription
            }
        }
    }
}
