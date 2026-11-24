import Observation
import SwiftUI

/// The queue page's scroll-driven song header offset.
///
/// It changes on every scroll tick. Keeping it in an observable object
/// instead of the player's own state means only the views that read it are
/// re-evaluated, not the whole Now Playing screen.
@Observable
final class NowPlayingQueueHeaderScroll {
    var offset: CGFloat = 0
}

/// Reads the queue header offset inside its own body so the dependency
/// belongs to this view rather than to the enclosing player.
struct NowPlayingQueueHeaderOffsetReader<Content: View>: View {
    let scroll: NowPlayingQueueHeaderScroll
    let isActive: Bool
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(isActive ? scroll.offset : 0)
    }
}
