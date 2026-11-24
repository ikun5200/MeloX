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
    /// The scale applied by the enclosing page transition. The artwork's
    /// corner clip uses this to keep a constant 12pt visible radius.
    var enclosingScale: CGFloat = 1
    /// The portrait player draws the image with a Core Animation layer and
    /// keeps only this view's shadow and bounce.
    var showsImage = true

    @State private var bounceScale: CGFloat = 1

    var body: some View {
        Group {
            if showsImage {
                ArtworkImage(
                    url: song.album?.artworkURL,
                    cornerRadius: 12,
                    enclosingScale: enclosingScale
                )
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .background {
            if isArtworkPage {
                // Fixed radius and fixed blur: the blurred texture is
                // built once and only transformed during the transition.
                // Play/pause intensity changes animate opacity instead of
                // invalidating the blur.
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.34))
                    .blur(radius: 26)
                    .offset(y: 15)
                    .opacity(player.isPlaying ? 1 : 0.53)
                    .transition(.opacity)
            }
        }
        .scaleEffect(bounceScale)
        .animation(
            accessibilityReduceMotion
                ? nil
                : NowPlayingPageTransition.motion.artworkResize.animation,
            value: player.isPlaying
        )
        .accessibilityElement()
        .accessibilityLabel(L10n.format("ui.song.artwork_accessibility", song.name))
        .task(id: player.isPlaying) {
            await animateBounce()
        }
    }

    private func animateBounce() async {
        if bounceScale != 1 {
            // Retarget a bounce in flight rather than snapping to rest.
            withAnimation(
                accessibilityReduceMotion ? nil : .smooth(duration: 0.2)
            ) {
                bounceScale = 1
            }
        }
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
