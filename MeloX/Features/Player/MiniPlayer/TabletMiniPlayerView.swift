import SwiftUI

/// Keep transport and seek controls separate from the artwork's expand button.
struct TabletMiniPlayerView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    let artworkTransitionID: String
    let artworkTransitionNamespace: Namespace.ID
    let onExpand: (NowPlayingPage?) -> Void

    @State private var availableWidth: CGFloat = 0
    @State private var playbackFeedbackCount = 0

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 16) {
                artworkButton(song: song)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                transportControls

                if availableWidth >= 900 {
                    seekControl(song: song)
                        .frame(width: min(availableWidth * 0.24, 280))
                }

                HStack(spacing: 4) {
                    if !song.isPodcastProgram {
                        Button {
                            onExpand(.lyrics)
                        } label: {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 19))
                                .frame(width: 44, height: 44)
                                .contentShape(.circle)
                        }
                        .accessibilityLabel("ui.settings.lyrics.title")
                        .accessibilityIdentifier("tablet-mini-lyrics")
                    }

                    Button {
                        onExpand(.queue)
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 19))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .accessibilityLabel("ui.player.queue")
                    .accessibilityIdentifier("tablet-mini-queue")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.subtlePress)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: 1_280)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if availableWidth < 900 {
                    progressLine(song: song)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableWidth = width
            }
        }
    }

    private func artworkButton(song: Song) -> some View {
        Button {
            onExpand(nil)
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(url: song.album?.artworkURL, cornerRadius: 8)
                    .frame(width: 46, height: 46)
                    .matchedTransitionSource(
                        id: artworkTransitionID,
                        in: artworkTransitionNamespace
                    )

                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(song.artistText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(song.id)
                    .transition(.opacity)
                }
                .animation(
                    reducesMotion ? nil : .easeOut(duration: 0.2),
                    value: song.id
                )
            }
            .contentShape(.rect)
        }
        .buttonStyle(SubtlePressButtonStyle(pressedScale: 1, pressedOpacity: 0.7))
        .accessibilityLabel(Text(verbatim: song.name))
        .accessibilityValue(Text(verbatim: song.artistText))
        .accessibilityIdentifier("tablet-mini-open")
    }

    private var transportControls: some View {
        HStack(spacing: 4) {
            Button {
                Task { await player.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .accessibilityLabel("ui.player.previous")

            Button {
                playbackFeedbackCount += 1
                player.togglePlayback()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .transition(.opacity)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .contentTransition(reducesMotion ? .identity : .symbolEffect(.replace))
                            .animation(
                                reducesMotion ? nil : .snappy(duration: 0.2, extraBounce: 0),
                                value: player.isPlaying
                            )
                            .transition(.opacity)
                    }
                }
                .frame(width: 48, height: 44)
                .animation(.easeOut(duration: 0.15), value: player.isLoading)
                .contentShape(.circle)
            }
            .accessibilityLabel(
                player.isPlaying
                    ? L10n.string("ui.player.pause")
                    : L10n.string("ui.common.play")
            )

            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .accessibilityLabel("ui.player.next")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: playbackFeedbackCount)
    }

    private func seekControl(song: Song) -> some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { max(0, min(player.progress, duration(for: song))) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...duration(for: song)
            )
            .sliderThumbVisibility(.hidden)
            .tint(.primary)
            .accessibilityLabel("ui.player.progress")

            HStack {
                Text(timeString(player.progress))
                Spacer()
                Text("−\(timeString(max(duration(for: song) - player.progress, 0)))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func progressLine(song: Song) -> some View {
        let fraction = CGFloat(min(max(player.progress / duration(for: song), 0), 1))
        return Capsule()
            .fill(.red.opacity(0.7))
            .scaleEffect(x: fraction, y: 1, anchor: .leading)
            .animation(reducesMotion ? nil : .linear(duration: 0.1), value: fraction)
            .frame(height: 2)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func duration(for song: Song) -> TimeInterval {
        max(player.duration, TimeInterval(song.durationMS) / 1_000, 1)
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
