import SwiftUI

enum HomeQuickAction: String, CaseIterable, Identifiable {
    case dailySongs
    case hotSongs
    case heartMode
    case privateRadar
    case privateRoaming
    case similarSongs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs")
        }
    }

    var systemImage: String {
        switch self {
        case .dailySongs:
            "calendar"
        case .hotSongs:
            "flame.fill"
        case .heartMode:
            "heart.fill"
        case .privateRadar:
            "dot.radiowaves.left.and.right"
        case .privateRoaming:
            "figure.walk.motion"
        case .similarSongs:
            "music.note.list"
        }
    }

    var eyebrow: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs.eyebrow")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs.eyebrow")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode.eyebrow")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar.eyebrow")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming.eyebrow")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs.eyebrow")
        }
    }

    var subtitle: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs.subtitle")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs.subtitle")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode.subtitle")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar.subtitle")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming.subtitle")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs.subtitle")
        }
    }

    var colors: [Color] {
        switch self {
        case .dailySongs:
            [.pink, .red]
        case .hotSongs:
            [.orange, .red]
        case .heartMode:
            [.pink, .purple]
        case .privateRadar:
            [.indigo, .purple]
        case .privateRoaming:
            [.cyan, .blue]
        case .similarSongs:
            [.mint, .teal]
        }
    }
}

struct HomeQuickActionsView: View {
    @Environment(\.musicShelfLayout) private var layout
    @ScaledMetric(relativeTo: .body) private var compactCardWidth = 230.0
    @State private var targetedActionID: String?

    let activeAction: HomeQuickAction?
    let perform: (HomeQuickAction) -> Void
    var configuration = HomeLayoutModuleConfiguration(id: "quickActions", cardSize: .compact)
    var actions = HomeLayoutPreferences().quickActions
    var editing: HomeLayoutEditing?

    private var visibleActions: [HomeLayoutQuickActionConfiguration] {
        actions.filter { $0.isVisible && HomeQuickAction(rawValue: $0.id) != nil }
    }

    var body: some View {
        if configuration.presentation == .grid {
            let metrics = MediaCardGridLayout(
                containerWidth: layout.containerWidth,
                horizontalPadding: layout.horizontalPadding,
                minimumItemWidth: configuration.cardSize == .compact ? 170 : 260,
                spacing: 16
            )
            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 16) {
                ForEach(visibleActions) { card($0) }
            }
            .padding(.horizontal, layout.horizontalPadding)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(visibleActions) { configuration in
                        card(configuration)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                isCompact(configuration)
                                    ? min(length, compactCardWidth)
                                    : min(length * 0.86, 340)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, layout.horizontalPadding, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func card(_ configuration: HomeLayoutQuickActionConfiguration) -> some View {
        if let action = HomeQuickAction(rawValue: configuration.id) {
            Group {
                if let editing {
                    Button { editing.editQuickAction(configuration.id) } label: { cardBody(action, configuration: configuration) }
                        .draggable(HomeLayoutQuickActionDragItem(sessionID: editing.sessionID, id: configuration.id))
                        .dropDestination(for: HomeLayoutQuickActionDragItem.self) { items, _ in
                            guard let item = items.first, item.sessionID == editing.sessionID,
                                  item.id != configuration.id, actions.contains(where: { $0.id == item.id }) else { return false }
                            editing.moveQuickAction(item.id, configuration.id)
                            return true
                        } isTargeted: { isTargeted in
                            if isTargeted { targetedActionID = configuration.id }
                            else if targetedActionID == configuration.id { targetedActionID = nil }
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(L10n.format("ui.settings.home_layout.edit_action", action.title))
                        .accessibilityHint("ui.settings.home_layout.action_drag_hint")
                } else {
                    Button { perform(action) } label: { cardBody(action, configuration: configuration) }
                        .disabled(activeAction != nil)
                        .accessibilityHint(accessibilityHint(for: action))
                }
            }
            .buttonStyle(.plain)
            .overlay {
                if targetedActionID == configuration.id {
                    RoundedRectangle(cornerRadius: 14).stroke(.tint, lineWidth: 3)
                }
            }
            .accessibilityIdentifier(editing == nil ? "home-action-\(action.id)" : "home-layout-action-\(action.id)")
        }
    }

    private func isCompact(_ action: HomeLayoutQuickActionConfiguration) -> Bool {
        (action.cardSize ?? configuration.cardSize) == .compact
    }

    private func cardBody(_ action: HomeQuickAction, configuration: HomeLayoutQuickActionConfiguration) -> some View {
        let compact = isCompact(configuration)
        return HomeEditorialCard(
            eyebrow: action.eyebrow,
            title: action.title,
            subtitle: action.subtitle,
            systemImage: action.systemImage,
            colors: action.colors,
            isCompact: compact
        )
        .overlay {
            if activeAction == action {
                ProgressView()
                    .controlSize(compact ? .regular : .large)
                    .padding(compact ? 14 : 22)
                    .background(.regularMaterial)
                    .clipShape(.circle)
            }
        }
    }

    private func accessibilityHint(for action: HomeQuickAction) -> String {
        switch action {
        case .dailySongs, .hotSongs, .privateRadar: L10n.format("ui.home.action.open_hint", action.title)
        case .heartMode, .privateRoaming, .similarSongs: L10n.format("ui.home.action.play_hint", action.title)
        }
    }
}
