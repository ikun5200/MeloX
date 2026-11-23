import SwiftUI

struct QQAccountSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NeteaseAPI.self) private var api
    @Environment(LibraryStore.self) private var library

    @State private var showsLogin = false

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
                        Text(
                            settings.qqCredential.loginType == 1
                                ? L10n.string(
                                    "ui.settings.qq_account.login_type.wechat"
                                )
                                : L10n.string(
                                    "ui.settings.qq_account.login_type.qq"
                                )
                        )
                        .foregroundStyle(.secondary)
                    }

                    Button("ui.qq_account.logout", role: .destructive) {
                        api.clearAccount()
                        library.clearAccountData()
                    }
                } else {
                    Button("ui.qq_account.login") {
                        showsLogin = true
                    }
                }
            } footer: {
                Text("ui.settings.qq_account.footer")
            }
        }
        .navigationTitle("ui.settings.qq_account.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsLogin) {
            QQLoginView()
        }
    }
}
