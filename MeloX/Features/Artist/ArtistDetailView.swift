import SwiftUI

struct ArtistDetailView: View {
    private let input: Artist

    init(artist: Artist) {
        input = artist
    }

    @Environment(NeteaseAPI.self) private var api
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var artist: Artist?
    @State private var artistDescription: String?
    @State private var similarArtists: [Artist] = []
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var phase: LoadingPhase = .loading
    @State private var reloadToken = 0

    var body: some View {
        Group {
            switch phase {
            case .loading where artist == nil:
                ProgressView("ui.artist.loading")
            case .failed(let message) where artist == nil:
                ConnectionUnavailableView(message: message) {
                    reloadToken += 1
                }
            default:
                if let artist {
                    content(artist)
                }
            }
        }
        .navigationTitle(artist?.name ?? L10n.string("ui.common.artist"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadToken) {
            guard artist == nil else { return }
            await load()
        }
    }

    private func content(_ artist: Artist) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkImage(url: artist.artworkURL, cornerRadius: 1_000)
                        .frame(width: 150, height: 150)
                    Text(artist.name)
                        .font(.title.bold())
                    if !artist.aliases.isEmpty {
                        Text(
                            L10n.joined(
                                artist.aliases,
                                separatorKey: "ui.common.artist_separator"
                            )
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await player.playAll(songs, sourceID: artist.id) }
                    } label: {
                        Text("ui.artist.play_popular_songs")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if let artistDescription, !artistDescription.isEmpty {
                Section("ui.artist.description") {
                    Text(artistDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !similarArtists.isEmpty {
                Section("ui.artist.similar") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(similarArtists) { similar in
                                NavigationLink(value: MusicRoute.artist(similar)) {
                                    VStack(spacing: 6) {
                                        ArtworkImage(
                                            url: similar.artworkURL,
                                            cornerRadius: 1_000
                                        )
                                        .frame(width: 76, height: 76)
                                        Text(similar.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 84)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("ui.artist.popular_songs") {
                ForEach(Array(songs.prefix(20).enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task {
                            await player.play(song, in: songs, sourceID: artist.id)
                        }
                    } label: {
                        TrackRowView(song: song, index: index)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.toggle(song: song)
                        } label: {
                            Label(
                                library.contains(song: song)
                                    ? L10n.string("ui.common.unfavorite")
                                    : L10n.string("ui.common.favorite"),
                                systemImage: library.contains(song: song) ? "heart.slash" : "heart"
                            )
                        }
                        .tint(.pink)
                    }
                }
            }

            Section("ui.common.albums") {
                ForEach(albums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        HStack(spacing: 12) {
                            ArtworkImage(url: album.artworkURL, cornerRadius: 7)
                                .frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.name)
                                    .lineLimit(1)
                                Text(album.type ?? L10n.string("ui.common.album"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .musicMatchedTransitionSource(for: MusicRoute.album(album))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        phase = .loading
        do {
            let loaded = try await api.artist(
                id: input.id,
                mid: input.mid
            )
            artist = loaded.0
            songs = loaded.1
            albums = loaded.2
            artistDescription = loaded.3
            if let artist {
                similarArtists = (
                    try? await api.similarArtists(
                        mid: artist.mid,
                        limit: 12
                    )
                ) ?? []
            }
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
