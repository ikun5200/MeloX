import SwiftUI

enum LyricsRefreshRate: Int, CaseIterable, Identifiable {
    case automatic = 0
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    static let defaultValue = LyricsRefreshRate.automatic
    static let lowPowerValue = LyricsRefreshRate.fps30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic:
            L10n.string("ui.settings.lyrics.animation.refresh_rate.automatic")
        case .fps30, .fps60, .fps90, .fps120:
            "\(rawValue) FPS"
        }
    }

    var minimumInterval: TimeInterval {
        switch self {
        case .automatic:
            1.0 / 120.0
        case .fps30, .fps60, .fps90, .fps120:
            1.0 / Double(rawValue)
        }
    }
}

private struct EffectiveLyricsRefreshRateKey: EnvironmentKey {
    static let defaultValue = LyricsRefreshRate.defaultValue
}

extension EnvironmentValues {
    var effectiveLyricsRefreshRate: LyricsRefreshRate {
        get { self[EffectiveLyricsRefreshRateKey.self] }
        set { self[EffectiveLyricsRefreshRateKey.self] = newValue }
    }
}
