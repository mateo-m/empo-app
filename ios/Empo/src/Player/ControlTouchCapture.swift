import GameProbe
import SwiftUI

// UIKit touch capture for the on-screen controls (`GameControls`).
//
// The controls previously used `DragGesture(minimumDistance: 0)`,
// which sits in SwiftUI's gesture graph alongside the overlay's
// edit-mode tap/drag recognizers. The graph resolves competing
// recognizers by deferring touch delivery until it can tell a tap
// from a drag. The finger moving past the tap tolerance or lifting.
// For game input that deferral is fatal: a tap became keydown+keyup
// in the same engine event batch (invisible to RGSS `Input.update`),
// and a motionless hold didn't engage until the finger drifted.
//
// Raw `touchesBegan/Moved/Ended` overrides have no arbitration:
// `onBegan` fires the moment the finger lands. UIKit also keeps
// routing a touch sequence to the view that received its begin even
// after the finger leaves its bounds, which is exactly the slide-off
// contract the D-pad documents.

/// UIKit-backed touch layer the on-screen controls read input from.
///
/// Every finger on the control is forwarded under its own
/// identifier, so a control can hold several at once: the D-pad
/// tracks each one, and a button stays pressed until the last one
/// lifts (`idle`).
struct ControlTouchCapture: UIViewRepresentable {
    /// The layer stays installed permanently and is gated by this
    /// flag instead of being inserted/removed with an `if` branch.
    /// Edit mode toggles inside `withAnimation`, and a conditionally
    /// removed overlay would leave with an animated opacity
    /// transition. Touchable for the whole fade, injecting game
    /// input AFTER the edit-mode release-all, and able to strand a
    /// mid-transition touch's keys when SwiftUI dismantles the view
    /// without delivering touchesEnded. `isUserInteractionEnabled`
    /// is not animatable, so this cutoff is instant.
    var enabled: Bool
    var onBegan: (Int, CGPoint) -> Void
    var onMoved: (Int, CGPoint) -> Void
    /// `idle` reports that this finger was the last one on the
    /// control, which is where a button releases its key.
    var onEnded: (Int, _ idle: Bool) -> Void

    func makeUIView(context: Context) -> ControlTouchCaptureView {
        let view = ControlTouchCaptureView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ControlTouchCaptureView, context: Context) {
        // Reassign on every update so the callbacks never capture a
        // stale copy of the owning view's state.
        apply(to: view)
    }

    private func apply(to view: ControlTouchCaptureView) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.setEnabled(enabled)
    }
}

final class ControlTouchCaptureView: UIView {
    var onBegan: ((Int, CGPoint) -> Void)?
    var onMoved: ((Int, CGPoint) -> Void)?
    var onEnded: ((Int, Bool) -> Void)?

    /// The fingers on this control (GameProbe, tested on Linux). It
    /// is the single owner of live-touch identity here: it names the
    /// moves and ends this view forwards, and it reports the lift
    /// that leaves the control idle, so no consumer needs to track
    /// the same fingers a second time. Multi-touch ACROSS controls
    /// (hold a direction + press A) works as before: each control
    /// owns its own capture view and UIKit routes every touch to the
    /// view under it independently.
    private var touchSet = ControlTouchSet<Int>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        // The SwiftUI content underneath carries the accessibility
        // label and traits. This layer is invisible plumbing.
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Turning the layer off must also abandon any in-flight touch:
    /// UIKit does not promise a touchesCancelled to a view that
    /// stops receiving events mid-sequence, and a silently dropped
    /// sequence would leave the engine holding keys.
    func setEnabled(_ enabled: Bool) {
        guard isUserInteractionEnabled != enabled else { return }
        isUserInteractionEnabled = enabled
        if !enabled {
            cancelActiveTouches()
        }
    }

    /// If the view is torn out of the hierarchy while a touch is
    /// live (SwiftUI reclaiming the control mid-press), end the
    /// sequence so held keys release even when UIKit never delivers
    /// the touch's end to the detached view.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelActiveTouches()
        }
    }

    /// Close every live touch as a real lift would, oldest first, so
    /// consumers need no separate cancellation path.
    private func cancelActiveTouches() {
        let abandoned = touchSet.reset()
        for (index, id) in abandoned.enumerated() {
            onEnded?(id, index == abandoned.count - 1)
        }
    }

    /// Names a finger for the length of its sequence. UIKit keeps one
    /// `UITouch` instance per finger while it is down, so its object
    /// identity is a stable key, and, unlike the object itself, an
    /// `Int` is safe to hold after the touch is recycled.
    private static func identifier(of touch: UITouch) -> Int {
        Int(bitPattern: ObjectIdentifier(touch))
    }

    /// Match the `.contentShape(Circle())` the controls declare: only
    /// the inscribed circle is hit-testable, so the frame's corners
    /// stay transparent to whatever sits below. Slide-off handling is
    /// unaffected. Once a touch begins inside, UIKit delivers the
    /// whole sequence here regardless of where the finger goes.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ControlHitShape.circleContains(
            width: bounds.width, height: bounds.height, x: point.x, y: point.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        dropVanishedTouches(in: event)
        for touch in touches {
            let id = Self.identifier(of: touch)
            // The set answers "is this finger mine?" for the moves
            // and ends that follow. Every finger is forwarded: what
            // a second one means belongs to the consumer.
            _ = touchSet.begin(id)
            onBegan?(id, touch.location(in: self))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        dropVanishedTouches(in: event)
        for touch in touches {
            let id = Self.identifier(of: touch)
            guard touchSet.isTracking(id) else { continue }
            onMoved?(id, touch.location(in: self))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracked(touches)
        dropVanishedTouches(in: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracked(touches)
        dropVanishedTouches(in: event)
    }

    private func endTracked(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = Self.identifier(of: touch)
            // A duplicate end (touchesEnded then touchesCancelled for
            // one touch) reports `notTracked` and is dropped here.
            let outcome = touchSet.end(id)
            guard outcome != .notTracked else { continue }
            onEnded?(id, outcome == .idle)
        }
    }

    /// Closes every tracked finger the event no longer lists as live.
    ///
    /// A control that holds keys must never outlive the finger that
    /// pressed them, and one lost `touchesEnded` used to be
    /// self-healing: the whole control released on the NEXT lift.
    /// Per-finger state ends that, so a dropped end would strand a
    /// key held for the rest of the session. The event carries every
    /// touch in the window with its current phase, so a tracked
    /// finger that is absent from it, or already ended in it, is gone.
    /// Close it exactly as a real lift would. Runs after the
    /// explicit ends of every delivery, so no event can leave a dead
    /// finger behind.
    ///
    /// A nil `allTouches` says nothing about the fingers on screen,
    /// so it must not be read as "none": leave the tracked ones alone
    /// and reconcile at the next delivery that does carry a list.
    private func dropVanishedTouches(in event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let stillDown = Set(
            allTouches
                .filter { $0.phase != .ended && $0.phase != .cancelled }
                .map(Self.identifier(of:))
        )
        for id in touchSet.live where !stillDown.contains(id) {
            let outcome = touchSet.end(id)
            onEnded?(id, outcome == .idle)
        }
    }
}
