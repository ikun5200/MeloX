import SwiftUI

enum NowPlayingPortraitCoordinateSpace {
    static let name = "nowPlayingPortraitPageContent"
}

struct NowPlayingPortraitArtwork: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(PlayerStore.self) private var player

    let song: Song
    let isArtworkPage: Bool

    @State private var bounceScale: CGFloat = 1

    var body: some View {
        ArtworkImage(
            url: song.album?.artworkURL,
            cornerRadius: 12
        )
        .background {
            // A static blurred shape scales with the artwork, so the
            // compositor can reuse it instead of re-rendering a dynamic
            // shadow on every frame of the lyrics transition.
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(shadowOpacity))
                .blur(radius: 26)
                .offset(y: 15)
        }
        .scaleEffect(bounceScale)
        .animation(
            accessibilityReduceMotion
                ? nil
                : .easeInOut(duration: 0.3),
            value: player.isPlaying
        )
        .accessibilityElement()
        .accessibilityLabel(L10n.format("ui.song.artwork_accessibility", song.name))
        .task(id: player.isPlaying) {
            await animateBounce()
        }
    }

    private var shadowOpacity: Double {
        guard isArtworkPage else { return 0 }
        return player.isPlaying ? 0.34 : 0.18
    }

    private func animateBounce() async {
        bounceScale = 1
        guard isArtworkPage, player.isPlaying, !accessibilityReduceMotion else {
            return
        }

        await Task.yield()
        withAnimation(.easeOut(duration: 0.17)) {
            bounceScale = 1.055
        }

        do {
            try await Task.sleep(for: .milliseconds(170))
        } catch {
            return
        }

        withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
            bounceScale = 1
        }
    }
}
