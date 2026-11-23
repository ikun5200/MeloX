import AVKit
import SwiftUI

struct MVDetailView: View {
    let context: MVRouteContext

    @Environment(NeteaseAPI.self) private var api

    @State private var detail: QQMVDetail?
    @State private var phase: LoadingPhase = .loading
    @State private var player: AVPlayer?
    @State private var showsPlayer = false
    @State private var isLoadingPlayback = false
    @State private var playbackError: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ArtworkImage(
                        url: detail?.coverURL.flatMap(URL.init(string:))
                            ?? context.artworkURLString.flatMap(URL.init(string:)),
                        cornerRadius: 12
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)

                    Text(detail?.name ?? context.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    if let artists = detail?.artists, !artists.isEmpty {
                        Text(
                            L10n.joined(
                                artists.map(\.name),
                                separatorKey: "ui.common.artist_separator"
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await play() }
                    } label: {
                        if isLoadingPlayback {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("ui.mv.watch", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoadingPlayback || phase == .loading)
                }
                .padding(.vertical, 8)
            }

            if let description = detail?.description,
               !description.isEmpty {
                Section("ui.mv.description") {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ui.mv.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .alert(
            "ui.mv.play_failed",
            isPresented: Binding(
                get: { playbackError != nil },
                set: { if !$0 { playbackError = nil } }
            )
        ) {
            Button("ui.common.ok", role: .cancel) {
                playbackError = nil
            }
        } message: {
            Text(playbackError ?? L10n.string("ui.common.unknown_error"))
        }
        .fullScreenCover(isPresented: $showsPlayer) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                }
                Button {
                    player?.pause()
                    showsPlayer = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                        .background(.black.opacity(0.55), in: .circle)
                        .foregroundStyle(.white)
                }
                .padding()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            detail = try await api.mvDetail(vid: context.vid)
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func play() async {
        guard !isLoadingPlayback else { return }
        isLoadingPlayback = true
        defer { isLoadingPlayback = false }
        do {
            let playback = try await api.mvPlayback(vid: context.vid)
            guard let url = playback.preferredURL else {
                throw APIError.noPlayableSource
            }
            let player = AVPlayer(url: url)
            self.player = player
            showsPlayer = true
            player.play()
        } catch is CancellationError {
            return
        } catch {
            playbackError = error.localizedDescription
        }
    }
}
