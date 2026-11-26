import AVKit
import SwiftUI

/// Opens the system route picker: AirPods, a HomePod, an Apple TV, or
/// anything else the phone can play to. The system owns the list and the
/// connection, so this only supplies the button.
struct AirPlayRouteButton: View {
    var tint: Color = .white

    var body: some View {
        AirPlayRoutePicker(tint: UIColor(tint))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .accessibilityLabel("ui.player.airplay")
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = tint
        view.activeTintColor = tint
        view.prioritizesVideoDevices = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}
