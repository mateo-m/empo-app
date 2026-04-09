import UIKit
import SwiftUI

// A portrait-only view controller that hosts the Library.
private class LibraryViewController: UIHostingController<GameLibraryView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var prefersStatusBarHidden: Bool { false }
}

// The window that shows the game library at launch and between game sessions.
// Installs itself automatically via ObjC +load (GameLibraryLoader.m).
// Dismisses when the user picks a game, unblocking the engine thread
// which is waiting in mkxp_waitForGamePath().
class GameLibraryWindow: UIWindow {

    private static var instance: GameLibraryWindow?

    /// Called by GameLibraryView when a game is tapped.
    @objc static func selectGame(_ path: String) {
        dismiss(withGamePath: path)
    }

    // Called once at app startup to create the library window.
    @objc static func install() {
        // Check if a scene is already active (we may have missed the notification)
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               scene.activationState == .foregroundActive {
                createWindow(in: windowScene)
                return
            }
        }

        // Otherwise listen for the first window scene to activate
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard instance == nil,
                  let scene = note.object as? UIWindowScene else { return }
            createWindow(in: scene)
        }
    }

    /// Re-show the library after a game session ends.
    /// Called from the UI layer (e.g. touch controls) after observing engine termination.
    @objc static func show() {
        guard instance == nil else { return } // already showing

        // Reload game list in case anything changed
        GameLibrary.shared.reload()

        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                createWindow(in: windowScene)
                return
            }
        }
    }

    private static func createWindow(in scene: UIWindowScene) {
        let window = GameLibraryWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .normal + 2  // above SDL + touch controls
        window.backgroundColor = .systemBackground
        window.isOpaque = true

        let vc = LibraryViewController(rootView: GameLibraryView())
        window.rootViewController = vc
        window.alpha = 0
        window.makeKeyAndVisible()

        UIView.animate(withDuration: 0.3) {
            window.alpha = 1
        }

        instance = window
    }

    private static func dismiss(withGamePath path: String) {
        guard let window = instance else { return }

        UIView.animate(withDuration: 0.3, animations: {
            window.alpha = 0
        }, completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
            instance = nil

            // Unblock the engine thread
            mkxp_setGamePath(path)
        })
    }
}
