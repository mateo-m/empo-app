import UIKit

/// Reparents SDL's game view into `AppWindow` while a game plays.
///
/// Two stacked UIWindows (SDL + AppWindow) break compositing on a
/// device. If we hide AppWindow and rely on SDL alone, the simulator
/// breaks. Single-window: the game UIView at the bottom of AppWindow,
/// SwiftUI on top, SDL's UIWindow hidden.
@MainActor
enum GameViewEmbedder {
    private static weak var embeddedGameView: UIView?
    private static weak var sdlWindow: UIWindow?

    static var isEmbedded: Bool { embeddedGameView != nil }

    /// SDL's game view when reparented into `AppWindow`, or nil before embed.
    static var embeddedView: UIView? { embeddedGameView }

    static func embedIfNeeded() -> Bool {
        guard embeddedGameView == nil else { return true }
        guard let window = sdlUIKitWindow() else { return false }
        guard let gameView = window.rootViewController?.view else { return false }
        guard let hostView = AppWindow.hostView else { return false }

        gameView.removeFromSuperview()
        gameView.frame = hostView.bounds
        gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.insertSubview(gameView, at: 0)

        window.isHidden = true
        embeddedGameView = gameView
        sdlWindow = window
        return true
    }

    static func embedWithRetry() {
        if embedIfNeeded() { return }
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                if embedIfNeeded() { return }
            }
        }
    }

    static func detach() {
        guard let gameView = embeddedGameView else { return }
        let window = sdlWindow

        gameView.removeFromSuperview()
        embeddedGameView = nil
        sdlWindow = nil

        guard let window else { return }
        window.isHidden = false
        if gameView.superview !== window {
            gameView.frame = window.bounds
            gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(gameView)
        }
    }

    private static func sdlUIKitWindow() -> UIWindow? {
        guard let ptr = mkxp_getSDLUIKitWindow() else { return nil }
        return Unmanaged<UIWindow>.fromOpaque(ptr).takeUnretainedValue()
    }
}
