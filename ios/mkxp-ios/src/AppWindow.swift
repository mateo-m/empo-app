import UIKit
import SwiftUI

// ============================================================================
// MARK: - AppRootViewController
// ============================================================================

/// Root VC that hosts the SwiftUI content as a child view controller.
private class AppRootViewController: UIViewController {

    private let hostingController: UIHostingController<RootView>

    init(rootView: RootView) {
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add hosting controller as child
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }

    // MARK: - Orientation & Status Bar

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        let phase = AppState.shared.phase
        switch phase {
        case .library, .quitting:
            return .portrait
        case .loading, .playing:
            return .allButUpsideDown
        }
    }

    override var prefersStatusBarHidden: Bool {
        let phase = AppState.shared.phase
        guard phase == .playing else { return false }
        let size = view.bounds.size
        return size.width > size.height // hide only in landscape gameplay
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarHidden: UIViewController? { nil }
}

// ============================================================================
// MARK: - AppWindow
// ============================================================================

/// Single UIWindow that floats above SDL's window and hosts all app UI.
/// In library/loading mode: opaque, covers SDL.
/// In player mode: transparent, passes non-control touches through to SDL.
class AppWindow: UIWindow {

    private static var instance: AppWindow?
    private var allowKeyWindow = false

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        windowLevel = .normal + 1 // above SDL window
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // No hitTest override needed. Controls handle their own key injection
    // via the bridge. Background touches are harmlessly absorbed — RGSS games
    // use keyboard input, not mouse/touch.

    // MARK: - Key Window Control

    /// In library/loading mode, this window must be key for SwiftUI interaction.
    /// In player mode, SDL needs to be key — except when keyboard mode is active.
    override var canBecomeKey: Bool {
        let phase = AppState.shared.phase
        if phase != .playing { return true }
        return allowKeyWindow
    }

    /// Called from PlayerView when keyboard mode needs the window to become key.
    @objc static func setAllowKeyWindow(_ allow: Bool) {
        guard let window = instance else { return }
        window.allowKeyWindow = allow
        if allow {
            window.makeKey()
        }
    }

    // MARK: - Installation

    /// Called once at app startup (from AppLoader.m via +load).
    @objc static func install() {
        // Check if a scene is already active
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

    private static func createWindow(in scene: UIWindowScene) {
        let window = AppWindow(windowScene: scene)
        window.frame = scene.screen.bounds

        let rootView = RootView()
        let vc = AppRootViewController(rootView: rootView)
        window.rootViewController = vc

        window.makeKeyAndVisible()
        instance = window

        // Observe phase changes to toggle pass-through and orientation
        var cancellable: Any?
        cancellable = AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak window] phase in
                _ = cancellable // prevent deallocation
                window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
    }
}
