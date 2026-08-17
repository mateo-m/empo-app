import SwiftUI
import UIKit

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

        addChild(hostingController)
        // UIHostingController defaults to an opaque systemBackground.
        // Set clear + isOpaque=false so the SDL/ANGLE window under
        // AppWindow can show through during gameplay (PlayerView is
        // mostly clear).
        let hosted = hostingController.view!
        hosted.backgroundColor = .clear
        hosted.isOpaque = false
        hosted.layer.isOpaque = false
        hosted.frame = view.bounds
        hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosted)
        hostingController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // SwiftUI can reintroduce an opaque hosting background after
        // hierarchy updates. Keep the pass-through contract intact.
        let hosted = hostingController.view!
        if hosted.backgroundColor != .clear || hosted.isOpaque {
            hosted.backgroundColor = .clear
            hosted.isOpaque = false
            hosted.layer.isOpaque = false
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    override var prefersStatusBarHidden: Bool {
        let phase = AppState.shared.phase
        guard phase == .playing else { return false }
        let size = view.bounds.size
        return size.width > size.height  // hide only in landscape gameplay
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarHidden: UIViewController? { nil }
}

/// Single UIWindow that floats above SDL's window and hosts all app UI.
/// In library/loading mode: opaque, covers SDL.
/// In player mode: transparent, passes non-control touches through to SDL.
class AppWindow: UIWindow {

    private static var instance: AppWindow?
    private var allowKeyWindow = false

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        windowLevel = .normal + 1  // above SDL window
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        let insets = safeAreaInsets
        mkxp_setSafeAreaInsets(
            Float(insets.top), Float(insets.bottom),
            Float(insets.left), Float(insets.right)
        )
    }

    /// During gameplay, route hosting-layer hits using chrome rects
    /// published by `PlayerView`. `_UIHostingView` is hit-testable
    /// across the full window and owns every SwiftUI gesture, so view
    /// identity cannot distinguish empty game area from chrome.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard AppState.shared.phase == .playing else { return hit }
        guard let hit else { return nil }

        let typeName = String(describing: type(of: hit))
        let isHostingLayer = typeName.contains("Hosting") || hit === rootViewController?.view

        if isHostingLayer {
            if ChromeHitRegions.contains(point) {
                return hit
            }
            // The touchable game zone IS the visible game surface
            // (the engine publishes it on every layout change), so
            // letterbox/controls-zone taps never become game mouse
            // input. UIKit routes each touch sequence to the view
            // that received its begin, so drags that start inside
            // keep delivering after the finger leaves the surface.
            // An empty rect means not yet published (boot): stay
            // permissive.
            let gameRect = EngineState.shared.gameRect
            if gameRect.isEmpty || gameRect.contains(point) {
                return GameViewEmbedder.embeddedView
            }
            return hit
        }

        var view: UIView? = hit
        while let current = view {
            if current is UIControl {
                return hit
            }
            if let recognizers = current.gestureRecognizers, !recognizers.isEmpty {
                return hit
            }
            view = current.superview
        }
        return hit
    }

    /// Any tap during play wakes the toolbar via
    /// `Notification.Name.gameAreaTouchBegan`. This includes taps
    /// outside the game surface that die on the hosting view.
    override func sendEvent(_ event: UIEvent) {
        if AppState.shared.phase == .playing,
            event.type == .touches,
            event.allTouches?.contains(where: { $0.phase == .began }) == true
        {
            NotificationCenter.default.post(name: .gameAreaTouchBegan, object: nil)
        }
        super.sendEvent(event)
    }

    // Controls handle their own key injection via the bridge.

    /// In library/loading: this window must be key for SwiftUI.
    /// In player: SDL needs key, unless keyboard mode is active or
    /// an error alert presents (SDL would steal OK taps).
    override var canBecomeKey: Bool {
        let state = AppState.shared
        if state.errorMessage != nil { return true }
        if state.infoMessage != nil { return true }
        if state.phase != .playing { return true }
        return allowKeyWindow
    }

    static var hostView: UIView? { instance?.rootViewController?.view }

    static var currentSafeArea: EdgeInsets {
        guard let window = instance else { return .init() }
        let insets = window.safeAreaInsets
        return EdgeInsets(
            top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    @objc static func setAllowKeyWindow(_ allow: Bool) {
        guard let window = instance else { return }
        window.allowKeyWindow = allow
        if allow {
            window.makeKey()
        } else {
            resignKeyToSDL()
        }
    }

    /// Returns UIKit key-window status to SDL after the overlay
    /// gives up `canBecomeKey` (e.g. loading -> playing).
    ///
    /// Never hand key status to a keyboard window. Once the system
    /// keyboard has shown, its `UITextEffectsWindow` joins
    /// `scene.windows`, and making it key while the keyboard
    /// dismisses briefly wakes the keyboard's own UI (the Memoji
    /// stickers splash with its "Continue" button).
    @objc static func resignKeyToSDL() {
        guard let overlay = instance, let scene = overlay.windowScene else { return }
        let candidates = scene.windows.filter { window in
            guard window !== overlay else { return false }
            let className = String(describing: type(of: window))
            return !className.contains("TextEffects") && !className.contains("Keyboard")
        }
        let sdl = candidates.first { String(describing: type(of: $0)).contains("SDL") }
        (sdl ?? candidates.first)?.makeKey()
    }

    /// `EmpoSceneDelegate` calls this once at app startup when UIKit
    /// connects the primary `UIWindowScene`.
    /// Checks for an active scene first, otherwise waits for one.
    /// During crash recovery, accepts any connected scene so the
    /// alert can appear without user interaction.
    @objc static func install() {
        install(in: nil)
    }

    /// Installs the SwiftUI overlay window. Pass the scene from
    /// `scene(_:willConnectTo:)` when available, so we do not wait
    /// for `foregroundActive` before the library shell can appear.
    @objc static func install(in preferredScene: UIWindowScene?) {
        if instance != nil {
            return
        }

        if let preferredScene {
            createWindow(in: preferredScene)
            return
        }

        let recovering = AppState.shared.pendingCrashRecovery

        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
                recovering || scene.activationState == .foregroundActive
            {
                createWindow(in: windowScene)
                return
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard instance == nil,
                let scene = note.object as? UIWindowScene
            else { return }
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

        let insets = window.safeAreaInsets
        mkxp_setSafeAreaInsets(
            Float(insets.top), Float(insets.bottom),
            Float(insets.left), Float(insets.right)
        )

        window.overrideUserInterfaceStyle = AppSettings.shared.theme.userInterfaceStyle

        // Brand tint for UIKit-backed elements (alerts, action sheets)
        window.tintColor = UIColor(.brand)

        observePhase(window: window)
        observeTheme(window: window)
        applyOverlayPresentationMode(window: window)
    }

    private static func observePhase(window: AppWindow) {
        withObservationTracking {
            _ = AppState.shared.phase
        } onChange: { [weak window] in
            Task { @MainActor in
                if let window {
                    applyOverlayPresentationMode(window: window)
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    observePhase(window: window)
                }
            }
        }
    }

    /// Keep AppWindow visible. Reparent SDL's game view here while
    /// the game plays, so one UIWindow owns the compositing stack.
    private static func applyOverlayPresentationMode(window: AppWindow) {
        let playing = AppState.shared.phase == .playing

        if playing {
            window.isHidden = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.layer.isOpaque = false
            if let root = window.rootViewController?.view {
                clearPassThroughBackdrop(in: root)
            }
            GameViewEmbedder.embedWithRetry()
        } else {
            GameViewEmbedder.detach()
            window.isHidden = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.layer.isOpaque = false
            if let root = window.rootViewController?.view {
                clearPassThroughBackdrop(in: root)
            }
        }
    }

    /// Strip opaque UIKit backdrops SwiftUI installs on hosting views.
    private static func clearPassThroughBackdrop(in view: UIView) {
        let typeName = String(describing: type(of: view))
        if typeName.contains("Hosting") {
            view.backgroundColor = .clear
            view.isOpaque = false
            view.layer.isOpaque = false
        }
        for subview in view.subviews {
            clearPassThroughBackdrop(in: subview)
        }
    }

    private static func observeTheme(window: AppWindow) {
        withObservationTracking {
            _ = AppSettings.shared.theme
        } onChange: { [weak window] in
            Task { @MainActor in
                window?.overrideUserInterfaceStyle = AppSettings.shared.theme.userInterfaceStyle
                if let window { observeTheme(window: window) }
            }
        }
    }
}
