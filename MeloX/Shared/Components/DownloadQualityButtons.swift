import SwiftUI

/// One button per quality a download can be requested at, for a menu.
struct DownloadQualityButtons: View {
    @Environment(AppSettings.self) private var settings

    let action: (MusicQuality) -> Void

    var body: some View {
        ForEach(settings.selectableMusicQualities) { quality in
            Button(settings.title(for: quality)) {
                action(quality)
            }
        }
    }
}
