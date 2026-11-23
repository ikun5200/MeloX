import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case recommended
    case music
    case explore
    case library
    case librarySongs
    case libraryPlaylists
    case libraryArtists
    case libraryAlbums
    case libraryDownloads
    case libraryHistory
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: L10n.string("ui.navigation.home")
        case .recommended: L10n.string("ui.navigation.recommended")
        case .music: L10n.string("ui.navigation.music")
        case .explore: L10n.string("ui.navigation.explore")
        case .library: L10n.string("ui.navigation.library")
        case .librarySongs: L10n.string("ui.navigation.library.liked_songs")
        case .libraryPlaylists: L10n.string("ui.navigation.library.liked_playlists")
        case .libraryArtists: L10n.string("ui.library.artists.title")
        case .libraryAlbums: L10n.string("ui.navigation.library.liked_albums")
        case .libraryDownloads: L10n.string("ui.navigation.downloads")
        case .libraryHistory: L10n.string("ui.navigation.recently_played")
        case .search: L10n.string("ui.navigation.search")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .recommended: "sparkles"
        case .music: "music.note"
        case .explore: "safari"
        case .library: "music.note.list"
        case .librarySongs: "heart"
        case .libraryPlaylists: "music.note.list"
        case .libraryArtists: "music.mic"
        case .libraryAlbums: "square.stack"
        case .libraryDownloads: "arrow.down.circle"
        case .libraryHistory: "clock"
        case .search: "magnifyingglass"
        }
    }

    var libraryPage: LibraryPage? {
        switch self {
        case .librarySongs: .songs
        case .libraryPlaylists: .playlists
        case .libraryArtists: .artists
        case .libraryAlbums: .albums
        case .libraryDownloads: .downloads
        case .libraryHistory: .history
        case .home,
             .recommended,
             .music,
             .explore,
             .library,
             .search:
            nil
        }
    }

    var settingsTitle: String {
        libraryPage?.settingsTitle ?? title
    }

    var requiredContentFeature: ContentFeature? {
        switch self {
        case .libraryDownloads:
            .downloads
        case .libraryHistory:
            .listeningHistory
        case .home,
             .recommended,
             .music,
             .explore,
             .library,
             .librarySongs,
             .libraryPlaylists,
             .libraryAlbums,
             .libraryArtists,
             .search:
            nil
        }
    }

    var allowedPlacements: [AppPagePlacement] {
        if self == .recommended {
            return [.home]
        }
        return libraryPage == nil
            ? [.home, .tabBar]
            : AppPagePlacement.allCases
    }

    static let movablePrimaryContentPages: [AppTab] = [
        .music,
        .explore,
        .library,
    ]

    static var libraryContentPages: [AppTab] {
        var pages: [AppTab] = [
            .librarySongs,
            .libraryPlaylists,
            .libraryAlbums,
            .libraryArtists,
        ]
        if AppFeatureAvailability.downloads {
            pages.append(.libraryDownloads)
        }
        pages.append(.libraryHistory)
        return pages
    }

    static var configurablePages: [AppTab] {
        movablePrimaryContentPages + libraryContentPages
    }

    init(libraryPage: LibraryPage) {
        switch libraryPage {
        case .songs:
            self = .librarySongs
        case .playlists:
            self = .libraryPlaylists
        case .artists:
            self = .libraryArtists
        case .albums:
            self = .libraryAlbums
        case .downloads:
            self = .libraryDownloads
        case .history:
            self = .libraryHistory
        }
    }
}

enum AppPagePlacement: String, CaseIterable, Identifiable {
    case home
    case tabBar
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: L10n.string("ui.navigation.home")
        case .tabBar: L10n.string("ui.settings.navigation.placement.tab_bar")
        case .library: L10n.string("ui.navigation.library")
        }
    }
}

enum LibraryPage: String, CaseIterable, Identifiable {
    case songs
    case playlists
    case artists
    case albums
    case downloads
    case history

    var id: String { rawValue }

    static var availableCases: [LibraryPage] {
        allCases.filter {
            AppFeatureAvailability.downloads || $0 != .downloads
        }
    }

    var title: String {
        switch self {
        case .songs: L10n.string("ui.common.songs")
        case .playlists: L10n.string("ui.common.playlists")
        case .artists: L10n.string("ui.library.artists.title")
        case .albums: L10n.string("ui.common.albums")
        case .downloads: L10n.string("ui.navigation.downloads")
        case .history: L10n.string("ui.common.history")
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .downloads: "arrow.down.circle"
        case .history: "clock"
        }
    }

    var settingsTitle: String {
        switch self {
        case .songs: L10n.string("ui.settings.navigation.page.liked_songs")
        case .playlists: L10n.string("ui.settings.navigation.page.liked_playlists")
        case .artists: L10n.string("ui.library.artists.title")
        case .albums: L10n.string("ui.settings.navigation.page.liked_albums")
        case .downloads: L10n.string("ui.navigation.downloads")
        case .history: L10n.string("ui.navigation.recently_played")
        }
    }

    var requiredContentFeature: ContentFeature? {
        switch self {
        case .downloads: .downloads
        case .history: .listeningHistory
        case .songs, .playlists, .albums, .artists: nil
        }
    }
}
