import SwiftUI
import UniformTypeIdentifiers

struct HomeLayoutEditing {
    let sessionID: UUID
    let moveModule: (String, String) -> Void
    let editModule: (String) -> Void
    let moveQuickAction: (String, String) -> Void
    let editQuickAction: (String) -> Void
}

nonisolated struct HomeLayoutModuleDragItem: Codable, Transferable {
    let sessionID: UUID
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.melox.home-layout-module"))
    }
}

nonisolated struct HomeLayoutQuickActionDragItem: Codable, Transferable {
    let sessionID: UUID
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.melox.home-layout-action"))
    }
}

struct HomeLayoutContentView: View {
    let sections: [HomeRecommendationSection]
    let preferences: HomeLayoutPreferences
    var activeAction: HomeQuickAction?
    var perform: (HomeQuickAction) -> Void = { _ in }
    var editing: HomeLayoutEditing?
    var onEdit: (() -> Void)?

    @State private var containerWidth: CGFloat = 390
    @State private var targetedModuleID: String?

    private var sectionsBySlot: [HomeRecommendationSlot: HomeRecommendationSection] {
        var result: [HomeRecommendationSlot: HomeRecommendationSection] = [:]
        for section in sections where result[section.slot] == nil { result[section.slot] = section }
        return result
    }

    private var visibleModules: [HomeLayoutModuleConfiguration] {
        preferences.modules.filter { configuration in
            guard configuration.isVisible, let module = HomeLayoutModule(rawValue: configuration.id) else { return false }
            if editing != nil { return true }
            if module == .quickActions { return preferences.quickActions.contains(where: \.isVisible) }
            return module.recommendationSlot.flatMap { sectionsBySlot[$0] } != nil
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            ForEach(visibleModules) { moduleView($0) }
            if visibleModules.isEmpty {
                ContentUnavailableView {
                    Label("ui.settings.home_layout.empty", systemImage: "rectangle.3.group")
                } description: {
                    Text("ui.settings.home_layout.empty_message")
                } actions: {
                    if let onEdit {
                        Button("ui.settings.home_layout.edit_home", action: onEdit).buttonStyle(.borderedProminent)
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .environment(\.musicShelfLayout, MusicShelfLayout(containerWidth: containerWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    @ViewBuilder
    private func moduleView(_ configuration: HomeLayoutModuleConfiguration) -> some View {
        if let editing, let module = HomeLayoutModule(rawValue: configuration.id) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                        .draggable(HomeLayoutModuleDragItem(sessionID: editing.sessionID, id: module.id))
                        .accessibilityElement()
                        .accessibilityLabel(L10n.format("ui.settings.home_layout.drag_module", module.title))
                        .accessibilityIdentifier("home-layout-drag-module-\(module.id)")
                        .accessibilityAction(named: L10n.string("ui.settings.home_layout.move_up")) { moveNeighbor(module.id, by: -1) }
                        .accessibilityAction(named: L10n.string("ui.settings.home_layout.move_down")) { moveNeighbor(module.id, by: 1) }
                    Text(module.title).font(.caption.weight(.semibold))
                    Spacer()
                    Button { editing.editModule(module.id) } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("ui.settings.home_layout.edit_module", module.title))
                    .accessibilityIdentifier("home-layout-edit-module-\(module.id)")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                moduleContent(configuration)
            }
            .padding(.vertical, 8)
            .background(.secondary.opacity(0.035), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(targetedModuleID == module.id ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: targetedModuleID == module.id ? 3 : 1)
            }
            .contentShape(.rect)
            .dropDestination(for: HomeLayoutModuleDragItem.self) { items, _ in
                guard let item = items.first, item.sessionID == editing.sessionID,
                      item.id != module.id, preferences.modules.contains(where: { $0.id == item.id }) else { return false }
                editing.moveModule(item.id, module.id)
                return true
            } isTargeted: { targeted in
                if targeted { targetedModuleID = module.id }
                else if targetedModuleID == module.id { targetedModuleID = nil }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-layout-module-\(module.id)")
        } else {
            moduleContent(configuration)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-module-\(configuration.id)")
        }
    }

    @ViewBuilder
    private func moduleContent(_ configuration: HomeLayoutModuleConfiguration) -> some View {
        if let module = HomeLayoutModule(rawValue: configuration.id) {
            if module == .quickActions {
                if preferences.quickActions.contains(where: \.isVisible) {
                    HomeQuickActionsView(
                        activeAction: activeAction,
                        perform: perform,
                        configuration: configuration,
                        actions: preferences.quickActions,
                        editing: editing
                    )
                } else if editing != nil {
                    Text("ui.settings.home_layout.actions_hidden")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                }
            } else if let slot = module.recommendationSlot, let section = sectionsBySlot[slot] {
                HomeRecommendationSectionView(
                    section: section,
                    cardSize: configuration.cardSize,
                    presentation: configuration.presentation,
                    isInteractive: editing == nil
                )
            } else if editing != nil {
                HomeMediaStrip(
                    title: module.title,
                    presentation: configuration.presentation,
                    minimumItemWidth: configuration.cardSize == .compact ? 126 : 166
                ) {
                    ForEach(0..<3, id: \.self) { _ in
                        HomeLayoutPlaceholderCard(compactArtworkSize: configuration.cardSize == .compact ? 126 : 166)
                    }
                }
            }
        }
    }

    private func moveNeighbor(_ id: String, by distance: Int) {
        let ids = visibleModules.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + distance) else { return }
        editing?.moveModule(id, ids[index + distance])
    }
}

private struct HomeLayoutPlaceholderCard: View {
    @Environment(\.musicShelfLayout) private var layout
    let compactArtworkSize: CGFloat

    var body: some View {
        let width = layout.artworkSize(compact: compactArtworkSize)
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.secondary.opacity(0.12))
                .overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.tertiary) }
                .frame(width: width, height: width)
            Text("ui.settings.home_layout.placeholder").font(.headline)
            Text("ui.settings.home_layout.placeholder_detail").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension HomeLayoutModule {
    var recommendationSlot: HomeRecommendationSlot? {
        switch self {
        case .quickActions: nil
        case .recommendedPlaylists: .recommendedPlaylists
        case .recentlyTrending: .recentlyTrending
        case .tailoredRecommendation: .tailoredRecommendation
        case .charts: .charts
        case .personalPlaylists: .personalPlaylists
        case .radarPlaylists: .radarPlaylists
        case .regionalHits: .regionalHits
        case .likedSongRoaming: .likedSongRoaming
        case .likedSongRecommendations: .likedSongRecommendations
        }
    }
}
