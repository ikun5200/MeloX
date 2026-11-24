import Nuke
import NukeUI
import SwiftUI

struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var aspectRatio: CGFloat = 1
    /// The scale applied by an enclosing `scaleEffect`. The corner radius
    /// is compensated for it so the visible radius stays constant while
    /// the artwork animates between the player and lyrics frames.
    var enclosingScale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        GeometryReader { proxy in
            LazyImage(
                request: imageRequest(for: proxy.size),
                transaction: Transaction(animation: imageLoadAnimation)
            ) { state in
                content(image: state.image, hasError: state.error != nil)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
            }
            .onDisappear(.lowerPriority)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(
            VisualRadiusRoundedRectangle(
                scale: enclosingScale,
                visualRadius: cornerRadius
            )
        )
        .accessibilityHidden(true)
    }

    private func imageRequest(for size: CGSize) -> ImageRequest? {
        guard let url else { return nil }

        var request = ImageRequest(url: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            size: CGSize(
                width: max(size.width, 1),
                height: max(size.height, 1)
            ),
            contentMode: .aspectFill
        )
        return request
    }

    private var imageLoadAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    @ViewBuilder
    private func content(image: Image?, hasError: Bool) -> some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        } else if hasError {
            placeholder
        } else {
            // No spinner: a list of thumbnails loading at once would show a
            // column of them, and the image fades in when it arrives.
            Color.secondary.opacity(0.12)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A rounded rectangle whose radius is compensated for an enclosing
/// `scaleEffect`, keeping the visible corner radius constant while the
/// scale animates. `scale` must be the same value that drives that
/// transform so both interpolate on the same curve.
struct VisualRadiusRoundedRectangle: Shape {
    var scale: CGFloat
    var visualRadius: CGFloat
    var style: RoundedCornerStyle = .continuous

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: visualRadius / max(scale, 0.001),
            style: style
        )
        .path(in: rect)
    }
}
