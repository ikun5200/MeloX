import SwiftUI

struct HomeRecommendationSectionView: View {
    @Environment(PlayerStore.self) private var player

    let section: HomeRecommendationSection
    var cardSize: HomeLayoutCardSize = .standard
    var presentation: HomeLayoutPresentation = .shelf
    var isInteractive = true

    var body: some View {
        switch section.content {
        case .playlists(let playlists): playlistSection(playlists)
        case .songs(let songs): songSection(songs)
        case .podcastPrograms: EmptyView()
        }
    }

    private func playlistSection(_ playlists: [Playlist]) -> some View {
        HomeMediaStrip(
            title: section.title,
            presentation: presentation,
            minimumItemWidth: cardSize == .compact ? 126 : 166
        ) {
            ForEach(playlists) { playlist in
                let route = playlistRoute(for: playlist)
                if isInteractive {
                    NavigationLink(value: route) {
                        HomePlaylistCard(playlist: playlist, compactArtworkSize: cardSize == .compact ? 126 : 166)
                    }
                    .buttonStyle(.plain)
                    .musicMatchedTransitionSource(for: route)
                } else {
                    HomePlaylistCard(playlist: playlist, compactArtworkSize: cardSize == .compact ? 126 : 166)
                }
            }
        }
    }

    private func songSection(_ songs: [Song]) -> some View {
        HomeMediaStrip(
            title: section.title,
            playAll: isInteractive ? { Task { await player.playAll(songs) } } : nil,
            presentation: presentation,
            minimumItemWidth: cardSize == .compact ? 120 : 154
        ) {
            ForEach(songs) { song in
                if isInteractive {
                    Button { Task { await player.play(song, in: songs) } } label: {
                        HomeSongCard(song: song, compactArtworkSize: cardSize == .compact ? 120 : 154)
                    }
                    .buttonStyle(.plain)
                } else {
                    HomeSongCard(song: song, compactArtworkSize: cardSize == .compact ? 120 : 154)
                }
            }
        }
    }

    private func playlistRoute(for playlist: Playlist) -> MusicRoute {
        section.slot == .charts ? .toplist(playlist) : .playlist(playlist)
    }
}

struct HomeMediaStrip<Content: View>: View {
    @Environment(\.musicShelfLayout) private var layout
    let title: String
    var playAll: (() -> Void)?
    var presentation: HomeLayoutPresentation = .shelf
    var minimumItemWidth: CGFloat = 154
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                Spacer()
                if let playAll {
                    Button(action: playAll) { Label("ui.common.play_all", systemImage: "play.fill") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel(L10n.format("ui.common.play_named", title))
                }
            }
            .padding(.horizontal, layout.horizontalPadding)

            if presentation == .grid {
                let metrics = MediaCardGridLayout(
                    containerWidth: layout.containerWidth,
                    horizontalPadding: layout.horizontalPadding,
                    minimumItemWidth: minimumItemWidth,
                    spacing: layout.spacing
                )
                LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 20) { content() }
                    .environment(\.musicShelfLayout, MusicShelfLayout(
                        containerWidth: layout.containerWidth,
                        artworkWidthOverride: metrics.itemWidth
                    ))
                    .padding(.horizontal, layout.horizontalPadding)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: layout.spacing) { content() }
                }
                .contentMargins(.horizontal, layout.horizontalPadding, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct HomeSongCard: View {
    @Environment(\.musicShelfLayout) private var layout
    let song: Song
    var compactArtworkSize: CGFloat = 154

    var body: some View {
        MediaCardView(
            title: song.name,
            subtitle: song.artistText,
            artworkURL: song.album?.artworkURL,
            artworkSize: layout.artworkSize(compact: compactArtworkSize)
        )
        .frame(width: layout.artworkSize(compact: compactArtworkSize))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
