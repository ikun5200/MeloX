import SwiftUI

/// Tells the listener a song could not be played, without taking the
/// screen away from them. It slides in under the status bar, and leaves by
/// itself, on a tap, or once the song plays after all.
struct PlaybackIssueBanner: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PlayerStore.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            if let issue = player.playbackIssue {
                banner(for: issue)
                    .transition(
                        accessibilityReduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            accessibilityReduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(duration: 0.4, bounce: 0.18),
            value: player.playbackIssue?.id
        )
        .allowsHitTesting(player.playbackIssue != nil)
    }

    private func banner(for issue: PlaybackIssue) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(issue.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Playback usually moves on by itself. The button is for when
            // it has stopped on the song that failed.
            if issue.offersNextSong,
               player.canPlayNext,
               player.currentSong?.id == issue.songID {
                Button("ui.player.next") {
                    player.dismissPlaybackIssue()
                    Task { await player.next() }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .contentShape(.rect)
        .onTapGesture {
            player.dismissPlaybackIssue()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: Text("ui.common.close")) {
            player.dismissPlaybackIssue()
        }
    }
}
