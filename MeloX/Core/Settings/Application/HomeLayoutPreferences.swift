import Foundation

nonisolated enum HomeLayoutModule: String, CaseIterable, Identifiable, Sendable {
    case quickActions
    case recommendedPlaylists
    case recentlyTrending
    case tailoredRecommendation
    case charts
    case personalPlaylists
    case radarPlaylists
    case regionalHits
    case likedSongRoaming
    case likedSongRecommendations

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .quickActions: "ui.settings.home_layout.quick_actions"
        case .recommendedPlaylists: "ui.home.section.recommended_playlists"
        case .recentlyTrending: "ui.home.section.recently_trending"
        case .tailoredRecommendation: "ui.home.section.tailored"
        case .charts: "ui.home.section.charts"
        case .personalPlaylists: "ui.home.section.your_playlists"
        case .radarPlaylists: "ui.home.section.your_radar"
        case .regionalHits: "ui.home.section.regional_hits"
        case .likedSongRoaming: "ui.home.section.liked_song_roaming"
        case .likedSongRecommendations: "ui.home.section.liked_song_recommendations"
        }
        return L10n.string(key)
    }
}

nonisolated enum HomeLayoutCardSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    var id: String { rawValue }
    var title: String { L10n.string("ui.settings.home_layout.size.\(rawValue)") }
}

nonisolated enum HomeLayoutPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case shelf
    case grid
    var id: String { rawValue }
    var title: String { L10n.string("ui.settings.home_layout.presentation.\(rawValue)") }
}

nonisolated struct HomeLayoutModuleConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var isVisible: Bool
    var cardSize: HomeLayoutCardSize
    var presentation: HomeLayoutPresentation

    init(id: String, isVisible: Bool = true, cardSize: HomeLayoutCardSize = .standard,
         presentation: HomeLayoutPresentation = .shelf) {
        self.id = id
        self.isVisible = isVisible
        self.cardSize = cardSize
        self.presentation = presentation
    }

    private enum CodingKeys: String, CodingKey { case id, isVisible, cardSize, presentation }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        cardSize = HomeLayoutCardSize(rawValue: try values.decodeIfPresent(String.self, forKey: .cardSize) ?? "") ?? .standard
        presentation = HomeLayoutPresentation(rawValue: try values.decodeIfPresent(String.self, forKey: .presentation) ?? "") ?? .shelf
    }
}

nonisolated struct HomeLayoutQuickActionConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var isVisible: Bool
    var cardSize: HomeLayoutCardSize?

    init(id: String, isVisible: Bool = true, cardSize: HomeLayoutCardSize? = nil) {
        self.id = id
        self.isVisible = isVisible
        self.cardSize = cardSize
    }

    private enum CodingKeys: String, CodingKey { case id, isVisible, cardSize }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        cardSize = try values.decodeIfPresent(String.self, forKey: .cardSize).flatMap(HomeLayoutCardSize.init(rawValue:))
    }
}

nonisolated struct HomeLayoutPreferences: Codable, Equatable, Sendable {
    let version = 1
    private(set) var modules: [HomeLayoutModuleConfiguration]
    private(set) var quickActions: [HomeLayoutQuickActionConfiguration]

    static let quickActionIDs = ["dailySongs", "hotSongs", "heartMode", "privateRadar", "privateRoaming", "similarSongs"]

    init(modules: [HomeLayoutModuleConfiguration]? = nil,
         quickActions: [HomeLayoutQuickActionConfiguration]? = nil,
         compactQuickActions: Bool = true) {
        let defaults = HomeLayoutModule.allCases.map {
            HomeLayoutModuleConfiguration(
                id: $0.id,
                cardSize: $0 == .quickActions && compactQuickActions ? .compact : .standard
            )
        }
        var seenModules: Set<String> = []
        let supportedModules = Set(defaults.map(\.id))
        self.modules = (modules ?? []).filter {
            supportedModules.contains($0.id) && seenModules.insert($0.id).inserted
        }
        self.modules.append(contentsOf: defaults.filter { !seenModules.contains($0.id) })

        var seenActions: Set<String> = []
        let supportedActions = Set(Self.quickActionIDs)
        self.quickActions = (quickActions ?? []).filter {
            supportedActions.contains($0.id) && seenActions.insert($0.id).inserted
        }
        self.quickActions.append(contentsOf: Self.quickActionIDs.filter { !seenActions.contains($0) }.map {
            HomeLayoutQuickActionConfiguration(id: $0)
        })
    }

    private enum CodingKeys: String, CodingKey { case version, modules, quickActions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modules: try values.decodeIfPresent([HomeLayoutModuleConfiguration].self, forKey: .modules),
            quickActions: try values.decodeIfPresent([HomeLayoutQuickActionConfiguration].self, forKey: .quickActions)
        )
    }

    var usesCompactQuickActions: Bool {
        module(HomeLayoutModule.quickActions.id)?.cardSize == .compact
    }

    func normalized() -> Self {
        Self(modules: modules, quickActions: quickActions, compactQuickActions: usesCompactQuickActions)
    }

    func module(_ id: String) -> HomeLayoutModuleConfiguration? {
        modules.first { $0.id == id }
    }

    func quickAction(_ id: String) -> HomeLayoutQuickActionConfiguration? {
        quickActions.first { $0.id == id }
    }

    mutating func updateModule(_ configuration: HomeLayoutModuleConfiguration) {
        guard let index = modules.firstIndex(where: { $0.id == configuration.id }) else { return }
        modules[index] = configuration
    }

    mutating func updateQuickAction(_ configuration: HomeLayoutQuickActionConfiguration) {
        guard let index = quickActions.firstIndex(where: { $0.id == configuration.id }) else { return }
        quickActions[index] = configuration
    }

    mutating func moveModule(_ id: String, to targetID: String) {
        guard let source = modules.firstIndex(where: { $0.id == id }),
              let target = modules.firstIndex(where: { $0.id == targetID }), source != target else { return }
        let moved = modules.remove(at: source)
        modules.insert(moved, at: target)
    }

    mutating func moveQuickAction(_ id: String, to targetID: String) {
        guard let source = quickActions.firstIndex(where: { $0.id == id }),
              let target = quickActions.firstIndex(where: { $0.id == targetID }), source != target else { return }
        let moved = quickActions.remove(at: source)
        quickActions.insert(moved, at: target)
    }
}
