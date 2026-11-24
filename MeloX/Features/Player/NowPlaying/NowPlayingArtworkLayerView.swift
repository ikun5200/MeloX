import Nuke
import SwiftUI
import UIKit

/// Portrait artwork whose movement between the player and lyrics frames is
/// driven by Core Animation. SwiftUI animations are committed from the main
/// thread every frame, so they stall whenever the page rebuild is busy; these
/// springs are handed to the render server once and keep running regardless.
struct NowPlayingArtworkLayerView: UIViewRepresentable {
    let url: URL?
    /// Size of the full artwork, used for the image request.
    let imageSize: CGSize
    /// Destination rectangle in this view's coordinate space.
    let targetFrame: CGRect
    let page: NowPlayingPage
    let isExpanded: Bool
    let isPlaying: Bool
    let reducesMotion: Bool

    func makeUIView(context: Context) -> NowPlayingArtworkLayerHostView {
        NowPlayingArtworkLayerHostView()
    }

    func updateUIView(
        _ view: NowPlayingArtworkLayerHostView,
        context: Context
    ) {
        view.apply(
            NowPlayingArtworkLayerHostView.Configuration(
                url: url,
                imageSize: imageSize,
                targetFrame: targetFrame,
                page: page,
                isExpanded: isExpanded,
                isPlaying: isPlaying,
                reducesMotion: reducesMotion
            )
        )
    }

    static func dismantleUIView(
        _ view: NowPlayingArtworkLayerHostView,
        coordinator: ()
    ) {
        view.cancelImageLoad()
    }
}

final class NowPlayingArtworkLayerHostView: UIView {
    struct Configuration: Equatable {
        let url: URL?
        let imageSize: CGSize
        let targetFrame: CGRect
        let page: NowPlayingPage
        let isExpanded: Bool
        let isPlaying: Bool
        let reducesMotion: Bool
    }

    private static let cornerRadius: CGFloat = 12
    private static let bounceAnimationKey = "playBounce"

    private let imageView = UIImageView()
    private var configuration: Configuration?
    private var imageTask: Task<Void, Never>?
    private var hasPlacedArtwork = false
    private var needsInitialBounce = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = true
        isUserInteractionEnabled = false

        // The artwork is a single layer: its bounds and position animate in
        // the render server while the corner radius stays a constant 12pt.
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Self.cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.layer.minificationFilter = .trilinear
        imageView.tintColor = .secondaryLabel
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, needsInitialBounce else { return }
        needsInitialBounce = false
        bounce()
    }

    func apply(_ new: Configuration) {
        let old = configuration
        guard old != new else { return }
        configuration = new

        if old?.url != new.url {
            loadImage(resetsCurrentImage: true)
        } else if old?.imageSize != new.imageSize {
            loadImage(resetsCurrentImage: false)
        }

        moveArtwork(from: old, to: new)
        updateBounce(from: old, to: new)
    }

    func cancelImageLoad() {
        imageTask?.cancel()
        imageTask = nil
    }

    // MARK: - Movement

    private func moveArtwork(from old: Configuration?, to new: Configuration) {
        let target = new.targetFrame
        guard target.width > 0, target.height > 0 else { return }

        let newCenter = CGPoint(x: target.midX, y: target.midY)
        let newSize = target.size
        let oldCenter = imageView.center
        let oldSize = imageView.bounds.size

        guard hasPlacedArtwork, let old else {
            imageView.bounds.size = newSize
            imageView.center = newCenter
            hasPlacedArtwork = true
            return
        }

        let tolerance: CGFloat = 0.01
        guard abs(oldCenter.x - newCenter.x) > tolerance
                || abs(oldCenter.y - newCenter.y) > tolerance
                || abs(oldSize.width - newSize.width) > tolerance
                || abs(oldSize.height - newSize.height) > tolerance else {
            return
        }

        imageView.bounds.size = newSize
        imageView.center = newCenter

        // Only a page change or the paused-artwork resize animates. Layout
        // measurements and the queue header's scroll tracking snap, exactly
        // as they did when these were value-scoped SwiftUI animations.
        let spring: (duration: TimeInterval, bounce: CGFloat)?
        if new.reducesMotion {
            spring = nil
        } else if old.page != new.page {
            spring = (0.5, 0.12)
        } else if old.isExpanded != new.isExpanded {
            spring = (0.48, 0)
        } else {
            spring = nil
        }
        guard let spring else { return }

        // Additive springs from the displacement back to zero stack on top
        // of any spring still in flight, so retargeting mid-transition stays
        // continuous instead of restarting from the presentation value.
        addAdditiveSpring(
            keyPath: "position",
            from: NSValue(
                cgPoint: CGPoint(
                    x: oldCenter.x - newCenter.x,
                    y: oldCenter.y - newCenter.y
                )
            ),
            to: NSValue(cgPoint: .zero),
            spring: spring
        )
        addAdditiveSpring(
            keyPath: "bounds.size",
            from: NSValue(
                cgSize: CGSize(
                    width: oldSize.width - newSize.width,
                    height: oldSize.height - newSize.height
                )
            ),
            to: NSValue(cgSize: .zero),
            spring: spring
        )
    }

    private func addAdditiveSpring(
        keyPath: String,
        from: NSValue,
        to: NSValue,
        spring: (duration: TimeInterval, bounce: CGFloat)
    ) {
        let animation = CASpringAnimation(
            perceptualDuration: spring.duration,
            bounce: spring.bounce
        )
        animation.keyPath = keyPath
        animation.isAdditive = true
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        imageView.layer.add(animation, forKey: nil)
    }

    // MARK: - Play bounce

    private func updateBounce(from old: Configuration?, to new: Configuration) {
        guard old?.isPlaying != new.isPlaying else { return }

        // Continue from wherever a bounce in flight has reached, so quick
        // play/pause taps retarget instead of snapping back to rest.
        let currentScale = imageView.layer.presentation()?
            .value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        imageView.layer.removeAnimation(forKey: Self.bounceAnimationKey)
        guard new.isPlaying,
              new.page == .artwork,
              !new.reducesMotion else {
            settleBounce(from: currentScale)
            return
        }

        if window == nil {
            needsInitialBounce = true
        } else {
            bounce(from: currentScale)
        }
    }

    private func settleBounce(from scale: CGFloat) {
        guard abs(scale - 1) > 0.001 else { return }
        let settle = CASpringAnimation(
            perceptualDuration: 0.2,
            bounce: 0
        )
        settle.keyPath = "transform.scale"
        settle.fromValue = scale
        settle.toValue = 1
        settle.duration = settle.settlingDuration
        imageView.layer.add(settle, forKey: Self.bounceAnimationKey)
    }

    private func bounce(from scale: CGFloat = 1) {
        let peakScale = 1.055
        let rise = CABasicAnimation(keyPath: "transform.scale")
        rise.fromValue = scale
        rise.toValue = peakScale
        rise.duration = 0.17
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let settle = CASpringAnimation(
            perceptualDuration: 0.42,
            bounce: 0.24
        )
        settle.keyPath = "transform.scale"
        settle.fromValue = peakScale
        settle.toValue = 1
        settle.beginTime = rise.duration
        settle.duration = settle.settlingDuration

        let group = CAAnimationGroup()
        group.animations = [rise, settle]
        group.duration = rise.duration + settle.duration
        imageView.layer.add(group, forKey: Self.bounceAnimationKey)
    }

    // MARK: - Image

    private func loadImage(resetsCurrentImage: Bool) {
        cancelImageLoad()
        guard let configuration, let url = configuration.url else {
            showPlaceholder()
            return
        }

        var request = ImageRequest(url: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            size: CGSize(
                width: max(configuration.imageSize.width, 1),
                height: max(configuration.imageSize.height, 1)
            ),
            contentMode: .aspectFill
        )

        let pipeline = ImagePipeline.shared
        if let cached = pipeline.cache.cachedImage(
            for: request,
            caches: [.memory]
        ) {
            show(cached.image, animated: false)
            return
        }

        if resetsCurrentImage {
            showLoading()
        }
        let animatesAppearance = !configuration.reducesMotion
        imageTask = Task { [weak self] in
            do {
                let image = try await pipeline.image(for: request)
                guard !Task.isCancelled else { return }
                self?.show(image, animated: animatesAppearance)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showPlaceholder()
            }
        }
    }

    private func show(_ image: UIImage, animated: Bool) {
        let update = {
            self.imageView.contentMode = .scaleAspectFill
            self.imageView.backgroundColor = nil
            self.imageView.image = image
        }
        guard animated else {
            update()
            return
        }
        UIView.transition(
            with: imageView,
            duration: 0.18,
            options: [.transitionCrossDissolve, .curveEaseOut],
            animations: update
        )
    }

    private func showLoading() {
        imageView.image = nil
        imageView.backgroundColor = Self.placeholderBackground
    }

    private func showPlaceholder() {
        imageView.contentMode = .center
        imageView.backgroundColor = Self.placeholderBackground
        imageView.image = UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(
                textStyle: .title2
            )
        )
    }

    private static var placeholderBackground: UIColor {
        .secondaryLabel.withAlphaComponent(0.12)
    }
}
