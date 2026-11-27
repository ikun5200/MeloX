import SwiftUI

struct HomeLayoutSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    @Environment(NeteaseAPI.self) private var api

    @State private var draft = HomeLayoutPreferences()
    @State private var initialLayout: HomeLayoutPreferences?
    @State private var sections: [HomeRecommendationSection] = []
    @State private var inspector: HomeLayoutInspector?
    @State private var showsDiscardConfirmation = false
    @State private var showsResetConfirmation = false
    @State private var showsHiddenItems = false
    @State private var hasCachedPreview = false
    @State private var activity = 0
    @State private var sessionID = UUID()

    private var isDirty: Bool { initialLayout.map { $0 != draft } ?? false }
    private var hiddenModules: [HomeLayoutModuleConfiguration] { draft.modules.filter { !$0.isVisible } }
    private var hiddenActions: [HomeLayoutQuickActionConfiguration] { draft.quickActions.filter { !$0.isVisible } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ui.settings.home_layout.description").font(.callout).foregroundStyle(.secondary)
                    Label("ui.settings.home_layout.preview", systemImage: "iphone.gen3")
                        .font(.headline)
                    Text(hasCachedPreview ? L10n.string("ui.settings.home_layout.cached_preview") : L10n.string("ui.settings.home_layout.placeholder_preview"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                if !hiddenModules.isEmpty || !hiddenActions.isEmpty { hiddenItems }

                if initialLayout != nil {
                    HomeLayoutContentView(
                        sections: sections,
                        preferences: draft,
                        editing: HomeLayoutEditing(
                            sessionID: sessionID,
                            moveModule: moveModule,
                            editModule: { inspector = .module($0) },
                            moveQuickAction: moveQuickAction,
                            editQuickAction: { inspector = .quickAction($0) }
                        ),
                        onEdit: { draft = HomeLayoutPreferences() }
                    )
                    .accessibilityIdentifier("home-layout-preview")

                    Button("ui.settings.home_layout.restore_default", systemImage: "arrow.counterclockwise") {
                        showsResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("home-layout-restore")
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .navigationTitle("ui.settings.home_layout.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("ui.common.cancel", action: requestDismiss)
                    .accessibilityIdentifier("home-layout-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("ui.common.save") {
                    settings.setHomeLayout(draft)
                    initialLayout = draft
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(initialLayout == nil)
                .accessibilityIdentifier("home-layout-save")
            }
        }
        .onAppear {
            guard initialLayout == nil else { return }
            initialLayout = settings.homeLayout
            draft = settings.homeLayout
        }
        .task(id: HomeLayoutPreviewRequest(accountScope: api.accountScope, musicArea: settings.musicArea)) {
            await loadPreview()
        }
        .sheet(item: $inspector) { inspector in
            NavigationStack {
                inspectorContent(inspector)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("ui.common.done") { self.inspector = nil }
                                .accessibilityIdentifier("home-layout-inspector-done")
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("ui.settings.home_layout.restore_title", isPresented: $showsResetConfirmation, titleVisibility: .visible) {
            Button("ui.settings.home_layout.restore_default", role: .destructive) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    draft = HomeLayoutPreferences()
                }
            }
            Button("ui.common.cancel", role: .cancel) {}
        } message: {
            Text("ui.settings.home_layout.restore_message")
        }
        .confirmationDialog("ui.settings.home_layout.discard_title", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {            Button("ui.settings.home_layout.discard", role: .destructive) {
                draft = initialLayout ?? HomeLayoutPreferences()
                dismiss()
            }
            Button("ui.settings.home_layout.keep_editing", role: .cancel) {}
        } message: {
            Text("ui.settings.home_layout.discard_message")
        }
        .sensoryFeedback(.selection, trigger: activity)
    }

    private var hiddenItems: some View {
        DisclosureGroup(isExpanded: $showsHiddenItems) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(hiddenModules) { configuration in
                    Button {
                        var restored = configuration
                        restored.isVisible = true
                        draft.updateModule(restored)
                    } label: {
                        Label(HomeLayoutModule(rawValue: configuration.id)?.title ?? configuration.id, systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("home-layout-restore-module-\(configuration.id)")
                }
                ForEach(hiddenActions) { configuration in
                    Button {
                        var restored = configuration
                        restored.isVisible = true
                        draft.updateQuickAction(restored)
                        if var module = draft.module("quickActions") {
                            module.isVisible = true
                            draft.updateModule(module)
                        }
                    } label: {
                        Label(HomeQuickAction(rawValue: configuration.id)?.title ?? configuration.id, systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("home-layout-restore-action-\(configuration.id)")
                }
            }
            .padding(.top, 10)
        } label: {
            Label(L10n.format("ui.settings.home_layout.hidden_count", hiddenModules.count + hiddenActions.count), systemImage: "eye.slash")
        }
        .padding(14)
        .background(.secondary.opacity(0.07), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("home-layout-hidden-items")
    }

    @ViewBuilder
    private func inspectorContent(_ inspector: HomeLayoutInspector) -> some View {
        switch inspector {
        case .module(let id):
            if let module = HomeLayoutModule(rawValue: id) {
                let binding = moduleBinding(id)
                Form {
                    Section {
                        Toggle("ui.settings.home_layout.visible", isOn: binding.isVisible)
                            .accessibilityIdentifier("home-layout-module-visible")
                        Picker("ui.settings.home_layout.presentation", selection: binding.presentation) {
                            ForEach(HomeLayoutPresentation.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("home-layout-module-presentation")
                        Picker("ui.settings.home_layout.card_size", selection: binding.cardSize) {
                            ForEach(HomeLayoutCardSize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("home-layout-module-size")
                    }
                    Section {
                        Button("ui.settings.home_layout.move_up", systemImage: "arrow.up") {
                            moveModuleNeighbor(id, by: -1)
                        }
                        .disabled(moduleNeighbor(id, distance: -1) == nil)
                        Button("ui.settings.home_layout.move_down", systemImage: "arrow.down") {
                            moveModuleNeighbor(id, by: 1)
                        }
                        .disabled(moduleNeighbor(id, distance: 1) == nil)
                    } footer: {
                        Text("ui.settings.home_layout.draft_note")
                    }
                }
                .navigationTitle(module.title)
            }
        case .quickAction(let id):
            if let action = HomeQuickAction(rawValue: id) {
                let binding = quickActionBinding(id)
                Form {
                    Section {
                        Toggle("ui.settings.home_layout.visible", isOn: binding.isVisible)
                            .accessibilityIdentifier("home-layout-action-visible")
                        Picker("ui.settings.home_layout.card_size", selection: binding.cardSize) {
                            Text("ui.settings.home_layout.inherit_size").tag(nil as HomeLayoutCardSize?)
                            ForEach(HomeLayoutCardSize.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .accessibilityIdentifier("home-layout-action-size")
                    }
                    Section {
                        Button("ui.settings.home_layout.move_up", systemImage: "arrow.left") { moveQuickActionNeighbor(id, by: -1) }
                            .disabled(actionNeighbor(id, distance: -1) == nil)
                        Button("ui.settings.home_layout.move_down", systemImage: "arrow.right") { moveQuickActionNeighbor(id, by: 1) }
                            .disabled(actionNeighbor(id, distance: 1) == nil)
                    } footer: { Text("ui.settings.home_layout.draft_note") }
                    Section {
                        HomeEditorialCard(
                            eyebrow: action.eyebrow,
                            title: action.title,
                            subtitle: action.subtitle,
                            systemImage: action.systemImage,
                            colors: action.colors,
                            isCompact: (binding.wrappedValue.cardSize ?? draft.module("quickActions")?.cardSize ?? .compact) == .compact
                        )
                        .allowsHitTesting(false)
                    }
                }
                .navigationTitle(action.title)
            }
        }
    }

    private func moduleBinding(_ id: String) -> Binding<HomeLayoutModuleConfiguration> {
        Binding(get: { draft.module(id) ?? .init(id: id) }, set: { draft.updateModule($0) })
    }

    private func quickActionBinding(_ id: String) -> Binding<HomeLayoutQuickActionConfiguration> {
        Binding(get: { draft.quickAction(id) ?? .init(id: id) }, set: { draft.updateQuickAction($0) })
    }

    private func moveModule(_ id: String, to target: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { draft.moveModule(id, to: target) }
        activity += 1
    }

    private func moveQuickAction(_ id: String, to target: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { draft.moveQuickAction(id, to: target) }
        activity += 1
    }

    private func moduleNeighbor(_ id: String, distance: Int) -> String? {
        neighbor(id, in: draft.modules.filter(\.isVisible).map(\.id), distance: distance)
    }

    private func actionNeighbor(_ id: String, distance: Int) -> String? {
        neighbor(id, in: draft.quickActions.filter(\.isVisible).map(\.id), distance: distance)
    }

    private func neighbor(_ id: String, in ids: [String], distance: Int) -> String? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + distance) else { return nil }
        return ids[index + distance]
    }

    private func moveModuleNeighbor(_ id: String, by distance: Int) {
        if let target = moduleNeighbor(id, distance: distance) { moveModule(id, to: target) }
    }

    private func moveQuickActionNeighbor(_ id: String, by distance: Int) {
        if let target = actionNeighbor(id, distance: distance) { moveQuickAction(id, to: target) }
    }

    private func requestDismiss() {
        if isDirty { showsDiscardConfirmation = true } else { dismiss() }
    }

    private func loadPreview() async {
        sections = []
        hasCachedPreview = false
        let scope = api.accountScope
        let area = settings.musicArea
        if let snapshot: HomeContentSnapshot = await api.pageContentCache.value(for: HomeContentSnapshot.cacheKey(musicArea: area)) {
            guard !Task.isCancelled, api.accountScope == scope, settings.musicArea == area else { return }
            sections = HomeRecommendationFeed(blocks: snapshot.payload.blocks, fallbacks: snapshot.fallbacks, includesPodcasts: false).sections
            hasCachedPreview = !sections.isEmpty
        }
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled, sections.isEmpty {
            sections = HomeRecommendationFeed(blocks: [], fallbacks: MeloXDesignPreview.homeFallbacks, includesPodcasts: false).sections
        }
        #endif
    }
}

private enum HomeLayoutInspector: Identifiable {
    case module(String)
    case quickAction(String)
    var id: String {
        switch self {
        case .module(let id): "module:\(id)"
        case .quickAction(let id): "action:\(id)"
        }
    }
}

private struct HomeLayoutPreviewRequest: Hashable {
    let accountScope: String
    let musicArea: String
}
