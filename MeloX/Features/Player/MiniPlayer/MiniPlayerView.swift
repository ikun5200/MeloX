import SwiftUI

struct MiniPlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(PlayerStore.self) private var player

    let artworkTransitionID: String
    let artworkTransitionNamespace: Namespace.ID
    let onExpand: () -> Void

    @State private var swipeOffset: CGFloat = 0
    @State private var feedbackCount = 0
    @GestureState private var isSwiping = false
    @State private var suppressesExpandTap = false

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: isInline ? 8 : 10) {
                Button {
                    // A track swipe that ends over the label must not also
                    // open the player.
                    guard !suppressesExpandTap else { return }
                    onExpand()
                } label: {
                    HStack(spacing: isInline ? 8 : 10) {
                        ArtworkImage(url: song.album?.artworkURL, cornerRadius: 6)
                            .frame(width: artworkSize, height: artworkSize)
                            .matchedTransitionSource(
                                id: artworkTransitionID,
                                in: artworkTransitionNamespace
                            )

                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                if !isInline {
                                    Text(song.artistText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(song.id)
                            .transition(.opacity)
                        }
                        .animation(
                            accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                            value: song.id
                        )
                        .offset(x: accessibilityReduceMotion ? 0 : swipeOffset)
                        .opacity(swipeTextOpacity)
                        .clipped()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(SubtlePressButtonStyle(pressedScale: 1, pressedOpacity: 0.7))
                .accessibilityLabel(Text(verbatim: song.name))
                .accessibilityValue(Text(verbatim: song.artistText))

                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36, height: 36)
                            .transition(.opacity)
                    } else {
                        Button {
                            feedbackCount += 1
                            player.togglePlayback()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3.weight(.semibold))
                                .contentTransition(
                                    accessibilityReduceMotion
                                        ? .identity
                                        : .symbolEffect(
                                            .replace.downUp.wholeSymbol,
                                            options: .speed(1.6)
                                        )
                                )
                                .animation(
                                    accessibilityReduceMotion
                                        ? nil
                                        : .snappy(duration: 0.2, extraBounce: 0),
                                    value: player.isPlaying
                                )
                                .frame(width: 36, height: 36)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.subtlePress)
                        .accessibilityLabel(
                            player.isPlaying
                                ? L10n.string("ui.player.pause")
                                : L10n.string("ui.common.play")
                        )
                        .transition(.opacity)
                    }
                }
                .frame(width: 36, height: 36)
                .animation(.easeOut(duration: 0.15), value: player.isLoading)

                if !isInline {
                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.subtlePress)
                    .accessibilityLabel("ui.player.next")
                }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 3 : 6)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .simultaneousGesture(trackSwipeGesture)
            .onChange(of: isSwiping) { _, isActive in
                if !isActive {
                    settleSwipe()
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: feedbackCount)
            .accessibilityAction(named: L10n.string("ui.player.previous")) {
                Task { await player.previous() }
            }
            .accessibilityAction(named: L10n.string("ui.player.next")) {
                Task { await player.next() }
            }
        }
    }

    private var isInline: Bool {
        placement == .inline
    }

    private var artworkSize: CGFloat {
        isInline ? 30 : 40
    }

    private var swipeTextOpacity: Double {
        1 - Double(min(abs(swipeOffset) / 60, 1)) * 0.5
    }

    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeActivationDistance)
            .updating($isSwiping) { _, state, _ in
                state = true
            }
            .onChanged { value in
                let travel = value.translation.width
                guard abs(travel) > abs(value.translation.height) else { return }
                // Start from zero at activation, then resist so the text stays close.
                let distance = max(abs(travel) - Self.swipeActivationDistance, 0)
                swipeOffset = (travel < 0 ? -distance : distance) * 0.55
                if distance > 0 {
                    suppressesExpandTap = true
                }
            }
            .onEnded { value in
                let travel = value.translation.width
                let predictedTravel = value.predictedEndTranslation.width
                let isHorizontal = abs(travel) > abs(value.translation.height)
                // A flick back toward the start cancels, whatever the distance.
                let keepsDirection = travel * predictedTravel > 0
                let isCommitted = isHorizontal
                    && keepsDirection
                    && (abs(travel) > 56 || abs(predictedTravel) > 140)

                if isCommitted {
                    feedbackCount += 1
                    if travel < 0 {
                        Task { await player.next() }
                    } else {
                        Task { await player.previous() }
                    }
                }
                settleSwipe()
            }
    }

    private static let swipeActivationDistance: CGFloat = 14

    private func settleSwipe() {
        if suppressesExpandTap {
            // The button's tap can be delivered just after the drag ends.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                suppressesExpandTap = false
            }
        }
        guard swipeOffset != 0 else { return }
        if accessibilityReduceMotion {
            swipeOffset = 0
        } else {
            withAnimation(.smooth(duration: 0.28)) {
                swipeOffset = 0
            }
        }
    }
}
