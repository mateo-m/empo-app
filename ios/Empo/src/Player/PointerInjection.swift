import UIKit

// Ticket 015 spike, path B.
//
// Today SDL's UIKit view receives game-area touches and turns them
// into mouse events itself. Path B gives those touches to a view Empo
// owns, which pushes them through `mkxp_injectPointerEvent`. The
// engine bridge is a dumb pipe, so the policy SDL applies in
// `SDL_touch.c` lives here instead:
//
//   - One finger owns the pointer from down to up. Every other finger
//     stays invisible to the game while it is held.
//   - A press sends motion and then the button. A lift sends the
//     button only. The bridge does that part.
//   - Coordinates clamp to the WINDOW, never to the game rect.
//     Essentials reads out-of-range GAME coordinates to detect that
//     the cursor left the game, so clamping to the game rect would
//     hide it.
//
// Routing does not change. `AppWindow.hitTest` still decides which
// touches belong to the game. Only the view it hands them to changes.

/// Owns the capture view for the pointer-injection A/B.
@MainActor
enum PointerInjection {

    private static var captureView: PointerInjectionView?

    /// The capture view, or nil when the spike toggle is off. This is
    /// what `AppWindow.hitTest` returns in place of SDL's view.
    static var activeView: UIView? {
        AppSettings.shared.pointerInjection ? captureView : nil
    }

    /// Adds the capture view under the SwiftUI host. Its depth among
    /// the siblings there does not matter, because `hitTest` returns
    /// it by name and it draws nothing.
    ///
    /// It stays installed while the toggle is off. `activeView` is
    /// the gate, so flipping the toggle mid-session never waits on
    /// view installation.
    static func install(in hostView: UIView) {
        guard captureView == nil else { return }

        let view = PointerInjectionView()
        view.frame = hostView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .clear
        view.isOpaque = false
        hostView.insertSubview(view, at: 0)
        captureView = view
    }

    static func remove() {
        captureView?.releaseOwner()
        captureView?.removeFromSuperview()
        captureView = nil
    }
}

/// Receives game-area touches and pushes them to the engine.
final class PointerInjectionView: UIView {

    /// The finger that owns the pointer. UIKit keeps delivering a
    /// touch sequence to the view that received its begin, so a drag
    /// that starts on the game surface keeps reporting after the
    /// finger leaves it. That is the behaviour Essentials expects.
    private weak var owner: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard owner == nil, let touch = touches.first else { return }
        owner = touch
        send(touch, phase: MKXP_POINTER_DOWN)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let owner, touches.contains(owner) else { return }
        send(owner, phase: MKXP_POINTER_MOVE)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: MKXP_POINTER_UP)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: MKXP_POINTER_CANCEL)
    }

    /// Releases the pointer if the session ends mid-touch. Without
    /// this the engine keeps the button down forever.
    func releaseOwner() {
        guard let owner else { return }
        send(owner, phase: MKXP_POINTER_CANCEL)
        self.owner = nil
    }

    private func finish(_ touches: Set<UITouch>, phase: MKXPPointerPhase) {
        guard let owner, touches.contains(owner) else { return }
        send(owner, phase: phase)
        self.owner = nil
    }

    // MARK: - Bridge

    private func send(_ touch: UITouch, phase: MKXPPointerPhase) {
        guard let window else { return }
        let point = touch.location(in: window)
        let bounds = window.bounds

        // SDL clamps to `window->w - 1` and `window->h - 1`, and
        // truncates toward zero. Match both.
        let x = min(max(Int(point.x), 0), max(Int(bounds.width) - 1, 0))
        let y = min(max(Int(point.y), 0), max(Int(bounds.height) - 1, 0))

        mkxp_injectPointerEvent(Int32(x), Int32(y), phase)

        if AppSettings.shared.debugLogs {
            // Shares a clock with the engine watcher, so the two logs
            // subtract cleanly. `UITouch.timestamp` and
            // `systemUptime` both count seconds since boot.
            let line = String(
                format: "inject phase=%d x=%d y=%d touch=%.6f push=%.6f",
                phase.rawValue, x, y,
                touch.timestamp, ProcessInfo.processInfo.systemUptime
            )
            PointerTrace.append(line)
            NSLog("[pointer] %@", line)
        }
    }
}
