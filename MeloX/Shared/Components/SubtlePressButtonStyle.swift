import SwiftUI

/// Press feedback for plain controls: a slight shrink and dim that lands
/// immediately on touch-down and eases back on release.
struct SubtlePressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.6

    func makeBody(configuration: Configuration) -> some View {
        SubtlePressButtonStyleBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            pressedScale: pressedScale,
            pressedOpacity: pressedOpacity
        )
    }
}

private struct SubtlePressButtonStyleBody<Label: View>: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let label: Label
    let isPressed: Bool
    let pressedScale: CGFloat
    let pressedOpacity: Double

    var body: some View {
        label
            .scaleEffect(
                isPressed && !accessibilityReduceMotion ? pressedScale : 1
            )
            .opacity(isPressed ? pressedOpacity : 1)
            // A custom style loses the system's disabled dimming.
            .opacity(isEnabled ? 1 : 0.4)
            // Touch-down is the latency-sensitive half, so it is short and
            // ease-out; the release settles a little more slowly.
            .animation(
                isPressed
                    ? .easeOut(duration: 0.12)
                    : .smooth(duration: 0.28),
                value: isPressed
            )
    }
}

extension ButtonStyle where Self == SubtlePressButtonStyle {
    static var subtlePress: SubtlePressButtonStyle { SubtlePressButtonStyle() }
}
