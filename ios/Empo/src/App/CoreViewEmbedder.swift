import UIKit

/// Hosts a `CoreSurface.view` session's `UIView` in `AppWindow`
/// while its game plays: the game view at the bottom of the host
/// view, SwiftUI (PlayerView chrome) on top - the same stacking
/// `GameViewEmbedder` produces for SDL, minus the window
/// reparenting dance SDL needs.
///
/// DORMANT: no registered core returns a `.view` surface until the
/// rmweb-core submodule lands and the MV/MZ import gate opens
/// (docs/plans/emulator-cores.md), so `embed` is unreachable today.
/// The type is deliberately unguarded - it only touches `UIView`,
/// so it compiles with or without `RmWebHost`.
///
/// TODO(rmweb-activation): verify the z-order on device - the game
/// view must sit under the hosting controller's SwiftUI view (index
/// 0 of `AppWindow.hostView`, matching `GameViewEmbedder`) and
/// behind the PlayerView controls overlay, and `AppWindow.hitTest`
/// must route non-chrome touches to it (see the fallback there).
@MainActor
enum CoreViewEmbedder {
    private static weak var embedded: UIView?

    /// The hosted game view. Nil before embed (and always nil for
    /// SDL sessions, which use `GameViewEmbedder.embeddedView`).
    static var embeddedView: UIView? { embedded }

    static func embed(_ gameView: UIView) {
        guard let hostView = AppWindow.hostView else { return }
        if embedded === gameView, gameView.superview === hostView { return }
        detach()
        gameView.removeFromSuperview()
        gameView.frame = hostView.bounds
        gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.insertSubview(gameView, at: 0)
        embedded = gameView
    }

    /// No-op unless a `.view` surface session is embedded. The view
    /// stays alive with its owning session; only the hosting ends.
    static func detach() {
        embedded?.removeFromSuperview()
        embedded = nil
    }
}
