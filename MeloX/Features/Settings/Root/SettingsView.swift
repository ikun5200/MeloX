import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(NeteaseAPI.self) private var api

    @State private var searchText = ""
    @State private var showsResetConfirmation = false
    @State private var isResettingSettings = false

    private var visibleSections: [SettingsCatalogSection] {
        SettingsCatalog.filteredSections(matching: searchText)
    }

    private var showsAccount: Bool {
        SettingsCatalog.matchesAccount(searchText)
    }

    private var showsReset: Bool {
        SettingsCatalog.matchesReset(searchText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                settingsContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 88)
        }
        .background(
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        )
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("MeloX")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "ui.settings.search.prompt")
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SettingsHomeToolbarTitle()
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("ui.common.close")
                .accessibilityHint("ui.settings.close.hint")
            }
        }
        .navigationDestination(for: SettingsRoute.self) { route in
            destination(for: route)
                .toolbar(.visible, for: .navigationBar)
        }
        .confirmationDialog(
            "ui.settings.reset.confirmation.title",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("ui.settings.reset.action", role: .destructive) {
                resetPlayerSettings()
            }
            Button("ui.common.cancel", role: .cancel) {}
        } message: {
            Text(
                AppFeatureAvailability.downloads
                    ? L10n.string("ui.settings.reset.message.downloads")
                    : L10n.string("ui.settings.reset.message")
            )
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        Group {
            if showsAccount, api.isUsingSourceResolver {
                NavigationLink(value: SettingsRoute.qqAccount) {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                library.profile?.nickname
                                    ?? L10n.string("ui.settings.qq_account.title")
                            )
                            .font(.headline)
                            Text(
                                library.isLoggedIn
                                    ? L10n.string("ui.account.logged_in")
                                    : L10n.string("ui.settings.qq_account.subtitle")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: 18, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            } else if showsAccount, !api.isUsingSourceResolver {
                SettingsAccountSection()
            }

            ForEach(visibleSections) { section in
                SettingsHomeSectionCard(section: section)
            }

            if showsReset {
                SettingsHomeResetCard(
                    isResetting: isResettingSettings
                ) {
                    showsResetConfirmation = true
                }
            }

            if !showsAccount && visibleSections.isEmpty && !showsReset {
                ContentUnavailableView(
                    "ui.settings.search.empty.title",
                    systemImage: "magnifyingglass",
                    description: Text("ui.settings.search.empty.description")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }
        }
    }

    @ViewBuilder
    private func destination(
        for route: SettingsRoute
    ) -> some View {
        switch route {
        case .accountHome:
            if let profile = library.profile {
                AccountHomeView(
                    initialProfile: profile,
                    initialDetail: library.accountDetail,
                    initialPlaylists: library.favoritePlaylists
                )
            } else {
                ContentUnavailableView(
                    "ui.settings.account.unavailable",
                    systemImage:
                        "person.crop.circle.badge.exclamationmark"
                )
            }
        case .playback:
            PlaybackSettingsView()
        case .playerAppearance:
            PlayerAppearanceSettingsView()
        case .lyrics:
            LyricsSettingsView()
        case .systemPlayback:
            SystemPlaybackSettingsView()
        case .general:
            GeneralSettingsView()
        case .tabLayout:
            TabLayoutSettingsView()
        case .homeLayout:
            HomeLayoutSettingsView()
        case .contentFeatures:
            ContentFeatureSettingsView()
        case .content:
            ContentSettingsView()
        case .sources:
            LXSourceSettingsView()
        case .qqAccount:
            QQAccountSettingsView()
        case .storage:
            StorageManagementView()
        case .skylineLyrics:
            SkylineLyricsSettingsView()
        case .floatingLyrics:
            FloatingLyricsSettingsView()
        case .developer:
            DeveloperSettingsView()
        case .about:
            AboutView()
        }
    }

    private func resetPlayerSettings() {
        guard !isResettingSettings else { return }
        isResettingSettings = true

        Task { @MainActor in
            await PlayerSettingsResetter.reset(
                settings: settings,
                player: player
            )
            isResettingSettings = false
        }
    }
}
