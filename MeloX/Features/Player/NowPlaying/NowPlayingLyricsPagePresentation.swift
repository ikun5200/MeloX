import SwiftUI

private struct NowPlayingLyricsPagePresentationModifier: ViewModifier {
    let visualState: NowPlayingPageVisualState
    let opacityTransition: NowPlayingInterruptibleProgress
    let spatialTransition: NowPlayingInterruptibleSpringProgress
    let opacitySpec: NowPlayingAnimationSpec
    let presentationScale: CGFloat
    let reducesMotion: Bool

    func body(content: Content) -> some View {
        let opacityProgress = opacityTransition.targetProgress
        let spatialProgress = spatialTransition.targetProgress
        let scale = presentationScale
            + (1 - presentationScale) * CGFloat(spatialProgress)

        content
            .offset(y: visualState.offsetY)
            .scaleEffect(scale)
            .opacity(
                opacitySpec.transformedProgress(opacityProgress)
            )
            .animation(
                reducesMotion ? nil : spatialAnimation,
                value: spatialTransition.targetProgress
            )
    }

    private var spatialAnimation: Animation {
        .interpolatingSpring(
            mass: spatialTransition.spring.mass,
            stiffness: spatialTransition.spring.stiffness,
            damping: spatialTransition.spring.damping,
            initialVelocity: spatialTransition.initialVelocity
        )
    }
}

extension View {
    func nowPlayingLyricsPagePresentation(
        visualState: NowPlayingPageVisualState,
        opacityTransition: NowPlayingInterruptibleProgress,
        spatialTransition: NowPlayingInterruptibleSpringProgress,
        opacitySpec: NowPlayingAnimationSpec,
        presentationScale: CGFloat,
        reducesMotion: Bool
    ) -> some View {
        modifier(
            NowPlayingLyricsPagePresentationModifier(
                visualState: visualState,
                opacityTransition: opacityTransition,
                spatialTransition: spatialTransition,
                opacitySpec: opacitySpec,
                presentationScale: presentationScale,
                reducesMotion: reducesMotion
            )
        )
    }

    func nowPlayingQueuePagePresentation(
        visualState: NowPlayingPageVisualState,
        opacityTransition: NowPlayingInterruptibleProgress,
        spatialTransition: NowPlayingInterruptibleSpringProgress,
        opacitySpec: NowPlayingAnimationSpec,
        presentationScale: CGFloat,
        reducesMotion: Bool
    ) -> some View {
        modifier(
            NowPlayingLyricsPagePresentationModifier(
                visualState: visualState,
                opacityTransition: opacityTransition,
                spatialTransition: spatialTransition,
                opacitySpec: opacitySpec,
                presentationScale: presentationScale,
                reducesMotion: reducesMotion
            )
        )
    }
}
