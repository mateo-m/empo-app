import GameProbe
import SwiftUI

// On-screen action button and D-pad, rendered with SwiftUI + the
// Liquid Glass material.
//
// Touch-dispatch semantics:
//   - `EngineSessionCoordinator.shared.injectKey(scancode:, pressed:)`
//     on press-down and release.
//   - Touches are captured by a UIKit `ControlTouchCapture` overlay
//     (raw touchesBegan/Moved/Ended), NOT by SwiftUI gestures. A
//     `DragGesture(minimumDistance: 0)` is subject to the gesture
//     graph's tap-vs-drag arbitration, which defers touch-down
//     delivery until the finger moves or lifts — so a quick tap
//     injected keydown+keyup in the same engine event batch and
//     `Input.update` never observed the press at all (see the
//     `injectKeyTap` comment in PlayerView). UIKit touch handling
//     has no arbitration: down fires the instant the finger lands.
//   - Action button: slide-off does NOT release the key.
//   - D-pad: `DPadTouchReducer` (GameProbe) owns the 8-wedge angular
//     mapping, inner 20% dead zone, cardinal-only inner ring (no
//     diagonals near the pivot, where thumb wobble would steer
//     4-way games sideways), slide-off release, and edge diffing,
//     so the exact shipped state machine is covered by the Linux
//     test suite. This file only renders its `active` set and
//     injects the edges it returns, in order.
//   - Edit mode disables the capture layer in place — an instant,
//     unanimated cutoff that also cancels any in-flight touch — so
//     the parent's drag gesture wins for repositioning.
//   - Explicit release-all on disappear / edit-mode transition so
//     keys never get stuck at the engine when SwiftUI reclaims the
//     view or the user enters edit mode mid-press.

// MARK: - Touch capture

/// UIKit-backed touch layer the on-screen controls read input from.
///
/// The controls previously used `DragGesture(minimumDistance: 0)`,
/// which sits in SwiftUI's gesture graph alongside the overlay's
/// edit-mode tap/drag recognizers. The graph resolves competing
/// recognizers by deferring touch delivery until it can tell a tap
/// from a drag — the finger moving past the tap tolerance or lifting.
/// For game input that deferral is fatal: a tap became keydown+keyup
/// in the same engine event batch (invisible to RGSS `Input.update`),
/// and a motionless hold didn't engage until the finger drifted.
///
/// Raw `touchesBegan/Moved/Ended` overrides have no arbitration:
/// `onBegan` fires the moment the finger lands. UIKit also keeps
/// routing a touch sequence to the view that received its begin even
/// after the finger leaves its bounds, which is exactly the
/// slide-off contract the D-pad documents.
private struct ControlTouchCapture: UIViewRepresentable {
    /// The layer stays installed permanently and is gated by this
    /// flag instead of being inserted/removed with an `if` branch.
    /// Edit mode toggles inside `withAnimation`, and a conditionally
    /// removed overlay would leave with an animated opacity
    /// transition — touchable for the whole fade, injecting game
    /// input AFTER the edit-mode release-all, and able to strand a
    /// mid-transition touch's keys when SwiftUI dismantles the view
    /// without delivering touchesEnded. `isUserInteractionEnabled`
    /// is not animatable, so this cutoff is instant.
    var enabled: Bool
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

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

private final class ControlTouchCaptureView: UIView {
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?

    /// Single-touch tracking (GameProbe, tested on Linux): the first
    /// touch to land owns the control until it ends, so a stray
    /// second finger can't restart or hijack the sequence.
    /// Multi-touch ACROSS controls (hold a direction + press A) still
    /// works: each control owns its own capture view and UIKit routes
    /// every touch to the view under it independently.
    private var gate = SingleTouchGate<ObjectIdentifier>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        // The SwiftUI content underneath carries the accessibility
        // label and traits; this layer is invisible plumbing.
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
            cancelActiveTouch()
        }
    }

    /// If the view is torn out of the hierarchy while a touch is
    /// live (SwiftUI reclaiming the control mid-press), end the
    /// sequence so held keys release even when UIKit never delivers
    /// the touch's end to the detached view.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelActiveTouch()
        }
    }

    private func cancelActiveTouch() {
        guard gate.reset() else { return }
        onEnded?()
    }

    /// Match the `.contentShape(Circle())` the controls declare: only
    /// the inscribed circle is hit-testable, so the frame's corners
    /// stay transparent to whatever sits below. Slide-off handling is
    /// unaffected — once a touch begins inside, UIKit delivers the
    /// whole sequence here regardless of where the finger goes.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ControlHitShape.circleContains(
            width: bounds.width, height: bounds.height, x: point.x, y: point.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, gate.begin(ObjectIdentifier(touch)) else { return }
        onBegan?(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { gate.isTracking(ObjectIdentifier($0)) }) else {
            return
        }
        onMoved?(touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endIfTracked(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endIfTracked(touches)
    }

    private func endIfTracked(_ touches: Set<UITouch>) {
        guard touches.contains(where: { gate.end(ObjectIdentifier($0)) }) else { return }
        onEnded?()
    }
}

// MARK: - Action button

/// Circular glass button. Presses emit a down/up event pair through
/// `EngineSessionCoordinator`. Holding and sliding the finger off the
/// button does NOT release the key.
struct ActionButton: View {
    let label: String
    let scancode: Int32
    let size: CGFloat
    let editing: Bool

    @State private var isPressed = false

    var body: some View {
        // Label drawn on top of a Liquid Glass circle. `.interactive()`
        // supplies the native press-style brightness on the glass
        // itself. A matching scaleEffect on the whole ZStack makes
        // the label scale together with the glass (the interactive
        // modifier alone only scales the glass layer, not content
        // drawn on top of it).
        ZStack {
            // Opaque backing under glass, for the same reason as the
            // D-pad: with the game view embedded in AppWindow, Liquid
            // Glass otherwise samples the Metal layer on device.
            Circle()
                .fill(Color.black)

            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)

            // Press highlight matching the D-pad arm gradient
            // (white 0.28 at the rim → clear toward the center).
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0), .white.opacity(0.28)],
                        center: .center,
                        startRadius: size * 0.15,
                        endRadius: size / 2
                    )
                )
                .opacity(isPressed ? 1 : 0)
                .animation(Motion.instant, value: isPressed)

            Text(label)
                .font(.system(size: size < 60 ? 12 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isPressed ? 1.0 : 0.9))
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: isPressed)
        // Force the dark Liquid Glass variant to match the D-pad.
        // Both controls pin to `.dark` so the glass material looks
        // consistent regardless of the system interface style or
        // the brightness of the game content behind them.
        .darkGlass()
        .contentShape(Circle())
        // VoiceOver: the visible glyph (`A`, `B`, `X`, `Y`, etc.) reads
        // as a letter otherwise, which gives no hint that it's a game
        // input. Announce it explicitly so users know they're holding
        // a gamepad button. The editing state is announced separately
        // by the layout's edit-mode container.
        .accessibilityLabel("\(label) button")
        .accessibilityAddTraits(.isButton)
        // Touch dispatch via the UIKit capture layer so the keydown
        // reaches the engine on touch-down, never deferred by gesture
        // arbitration. Disabled (not removed) while editing: touches
        // then fall through to the parent's tap-to-edit and
        // drag-to-reposition gestures, and the instant interaction
        // cutoff closes the animated-removal window described on
        // `ControlTouchCapture.enabled`.
        .overlay {
            ControlTouchCapture(
                enabled: !editing,
                onBegan: { _ in press() },
                // Slide-off keeps the key held by design: no
                // location tracking while the finger moves.
                onMoved: { _ in },
                onEnded: { releaseIfHeld() }
            )
        }
        // If the user enters edit mode while this button is pressed, or
        // the button is removed from the layout while pressed, release
        // the key explicitly.
        .onChange(of: editing) { _, newValue in
            if newValue {
                releaseIfHeld()
            }
        }
        .onDisappear {
            releaseIfHeld()
        }
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        Haptics.controllerTap()
        EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: true)
    }

    private func releaseIfHeld() {
        guard isPressed else { return }
        isPressed = false
        EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: false)
    }
}

// MARK: - D-pad

/// Eight-wedge D-pad rendered as a physical-looking rounded plus
/// shape. The four arms are individual glass surfaces that brighten
/// when their direction is active. A small center dot marks the
/// pivot (and the dead zone).
///
/// Diagonals press two scancodes at once. The bitwise diff across
/// touch-move updates means a steady hold emits zero events, and a
/// straight slide from NE to SE releases UP and presses DOWN while
/// RIGHT stays held throughout (no stutter).
///
/// The hit-test shape is a full circle that inscribes the plus
/// outline, so touches in the outer "corners" between arms still
/// engage (the angular wedge map decides which direction they
/// represent). This keeps hit-testing lenient even with a visually
/// spare plus silhouette.
struct DPad: View {
    let size: CGFloat
    let editing: Bool

    /// Touch-to-directions state machine (GameProbe, tested on
    /// Linux): 8-wedge angular map, inner dead zone, cardinal-only
    /// inner ring, slide-off release, and press/release edge
    /// diffing. The view renders `dpadState.active` and injects
    /// whatever edges the reducer returns, in order.
    @State private var dpadState = DPadTouchReducer()

    /// Width of each arm of the plus, as a fraction of the total
    /// bounding box. 0.36 gives balanced proportions where the center
    /// square feels integral to the arms rather than a visual seam.
    private let armFraction: CGFloat = 0.36

    /// Corner radius of the plus's OUTER corners (arm tips), as a
    /// fraction of armWidth.
    ///   0.5  = fully-rounded arm caps (very soft)
    ///   0.25 = slightly rounded corners (squarer, game-pad-like)
    ///   0.1  = barely rounded (sharp, mechanical)
    private let cornerFraction: CGFloat = 0.25

    /// Inner-corner fillet radius, as a fraction of armWidth. Rounds
    /// the four notches between the arms so the plus-to-square
    /// transitions don't feel sharp. Small values (0.05-0.15) give
    /// a subtle fillet. 0 keeps the notches perfectly square.
    private let innerCornerFraction: CGFloat = 0.1

    var body: some View {
        let plus = DPadPlusShape(
            armFraction: armFraction,
            cornerFraction: cornerFraction,
            innerCornerFraction: innerCornerFraction
        )

        let pressed = !dpadState.active.isEmpty

        // Everything here lives inside a single scaled ZStack so the
        // glass plus, per-arm highlights, chevrons, and center dot all
        // spring together on press (same structure as v0.2.6).
        ZStack {
            // Opaque backing under glass. With the game view embedded
            // in AppWindow, Liquid Glass otherwise samples the Metal
            // layer and blooms a clipped top/left highlight on device.
            // Black keeps the lit rim consistent with v0.2.6 (controls
            // over letterbox black).
            plus
                .fill(Color.black)

            plus
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: plus)

            // Frame arm highlights to each arm's local rect so
            // tip→center UnitPoints are identical for every direction.
            // A fill on a Shape that only draws in one corner of the
            // full D-pad frame made up/left gradients resolve
            // differently from down/right on device.
            ZStack {
                ForEach(DPadDirection.allCases, id: \.self) { dir in
                    let arm = DPadArmGeometry.frame(
                        direction: dir, size: size, armFraction: armFraction)
                    let radii = DPadArmGeometry.cornerRadii(
                        direction: dir, size: size, armFraction: armFraction,
                        cornerFraction: cornerFraction)
                    UnevenRoundedRectangle(cornerRadii: radii)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0)],
                                startPoint: dir.localHighlightStart,
                                endPoint: dir.localHighlightEnd
                            )
                        )
                        .frame(width: arm.width, height: arm.height)
                        .position(x: arm.midX, y: arm.midY)
                        .opacity(dpadState.active.contains(dir) ? 1 : 0)
                        .animation(Motion.instant, value: dpadState.active)
                }
            }
            .clipShape(plus)

            ForEach(DPadDirection.allCases, id: \.self) { dir in
                Image(systemName: dir.symbolName)
                    .font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundStyle(.white.opacity(dpadState.active.contains(dir) ? 1.0 : 0.55))
                    .offset(dir.glyphOffset(size: size, armFraction: armFraction))
            }

            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        // Scale the whole stack on press so glass, highlights,
        // chevrons, and the center dot all spring together.
        .scaleEffect(pressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: pressed)
        // Force the dark Liquid Glass variant so the plus clip shape
        // doesn't render noticeably brighter than the action buttons'
        // circles.
        .darkGlass()
        .contentShape(Circle())
        .accessibilityLabel("Directional pad")
        .accessibilityHint("Touch and drag to move the character")
        .accessibilityAddTraits(.allowsDirectInteraction)
        // Touch dispatch via the UIKit capture layer: a tap must press
        // its direction on touch-down (a whole down/up pair delivered
        // at lift lands in one engine event batch and moves the
        // character zero tiles), and a motionless hold must engage
        // without the finger having to travel first. UIKit keeps
        // delivering the touch sequence to this layer after the finger
        // leaves its bounds, which is exactly the slide-off contract
        // `DPadTouchReducer` documents.
        .overlay {
            ControlTouchCapture(
                enabled: !editing,
                onBegan: { apply(dpadState.touchChanged(x: $0.x, y: $0.y, size: size)) },
                onMoved: { apply(dpadState.touchChanged(x: $0.x, y: $0.y, size: size)) },
                onEnded: { apply(dpadState.touchEnded()) }
            )
        }
        .onChange(of: editing) { _, newValue in
            if newValue {
                apply(dpadState.touchEnded())
            }
        }
        .onDisappear {
            apply(dpadState.touchEnded())
        }
    }

    /// Inject the reducer's edges in array order — the reducer lists
    /// releases before presses so a wedge transition never
    /// momentarily holds opposing directions — and fire a haptic tap
    /// when a new direction enters the active set (one buzz per wedge
    /// transition rather than one continuous buzz while held).
    private func apply(_ edges: [DPadTouchReducer.Edge]) {
        for edge in edges {
            EngineSessionCoordinator.shared.injectKey(
                scancode: edge.direction.scancode, pressed: edge.pressed)
        }
        if edges.contains(where: { $0.pressed }) {
            Haptics.controllerTap()
        }
    }
}

// MARK: - D-pad supporting types

/// The reducer's direction enum doubles as the app-side D-pad
/// direction: scancode mapping and rendering geometry attach here as
/// extensions, so the view and the tested state machine share one
/// direction vocabulary instead of maintaining a parallel enum.
typealias DPadDirection = DPadTouchReducer.Direction

extension DPadDirection {
    var scancode: Int32 {
        switch self {
        case .up: Int32(MKXP_SCANCODE_UP)
        case .down: Int32(MKXP_SCANCODE_DOWN)
        case .left: Int32(MKXP_SCANCODE_LEFT)
        case .right: Int32(MKXP_SCANCODE_RIGHT)
        }
    }

    var symbolName: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    /// Offset from the center of the D-pad at which to draw the
    /// chevron for this direction. Centered within the arm's outer
    /// rectangle. The arm spans `armLen = (size - armW) / 2` from
    /// the outer edge to the center-square edge. Its midpoint is
    /// at `armLen/2` from the outer edge, which is `size/2 - armLen/2
    /// = (size + armW) / 4` from the D-pad center. That offset puts
    /// the chevron in the visual center of each arm, not near the tip.
    func glyphOffset(size: CGFloat, armFraction: CGFloat) -> CGSize {
        let d = (size + size * armFraction) / 4
        switch self {
        case .up: return CGSize(width: 0, height: -d)
        case .down: return CGSize(width: 0, height: d)
        case .left: return CGSize(width: -d, height: 0)
        case .right: return CGSize(width: d, height: 0)
        }
    }

    /// Tip → center gradient in the arm's *local* frame (after the
    /// highlight view is sized to that arm). Same UnitPoints for every
    /// direction so up/left match down/right on device.
    var localHighlightStart: UnitPoint {
        switch self {
        case .up: return .top
        case .down: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    var localHighlightEnd: UnitPoint {
        switch self {
        case .up: return .bottom
        case .down: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

// MARK: - D-pad decorative shapes

/// Rounded plus silhouette that forms the D-pad's base. Built as a
/// single closed polygon (no overlapping sub-paths), so there are no
/// internal seams where two rectangles used to meet. `cornerFraction`
/// rounds the 8 outer corners. `innerCornerFraction` fillets the 4
/// inner corners (the notches between arms) with a concave arc for a
/// friendlier silhouette.
///
/// `armFraction` is the width of each arm as a fraction of the
/// bounding box. 0.3 - 0.4 gives a balanced "plus" feel. Below that
/// it starts to look spindly. Above that the arms merge into a
/// square-with-notches look.
private struct DPadPlusShape: Shape {
    let armFraction: CGFloat
    let cornerFraction: CGFloat
    let innerCornerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let armW = rect.width * armFraction
        let armH = rect.height * armFraction
        let cornerR = min(armW * cornerFraction, armW / 2, armH / 2)
        let hInset = (rect.height - armH) / 2  // y of horizontal bar top
        let vInset = (rect.width - armW) / 2  // x of vertical bar left
        // The inner fillet must not exceed half the length of the
        // arm's inner side or half the vInset/hInset (distance from
        // center-square edge to the outer boundary).
        let innerR = min(
            armW * innerCornerFraction,
            vInset / 2,
            hInset / 2,
            armW / 2,
            armH / 2
        )
        let w = rect.width
        let h = rect.height

        // Walk the plus clockwise from the top of the top arm.
        // 8 outer arm-tip corners (rounded convex) and 4 inner
        // notches (rounded concave with addQuadCurve).
        var p = Path()
        // Top arm, top-left corner (rounded convex).
        p.move(to: CGPoint(x: vInset, y: cornerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset + cornerR, y: 0),
            control: CGPoint(x: vInset, y: 0)
        )
        // Top edge to top-right corner of top arm.
        p.addLine(to: CGPoint(x: vInset + armW - cornerR, y: 0))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW, y: cornerR),
            control: CGPoint(x: vInset + armW, y: 0)
        )
        // Right edge of top arm, down to the inner notch
        // (stop innerR short).
        p.addLine(to: CGPoint(x: vInset + armW, y: hInset - innerR))
        // INNER notch (top-right): concave fillet into the right arm.
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW + innerR, y: hInset),
            control: CGPoint(x: vInset + armW, y: hInset)
        )
        // Top edge of right arm, to outer corner.
        p.addLine(to: CGPoint(x: w - cornerR, y: hInset))
        p.addQuadCurve(
            to: CGPoint(x: w, y: hInset + cornerR),
            control: CGPoint(x: w, y: hInset)
        )
        // Right edge down to bottom-right outer corner.
        p.addLine(to: CGPoint(x: w, y: hInset + armH - cornerR))
        p.addQuadCurve(
            to: CGPoint(x: w - cornerR, y: hInset + armH),
            control: CGPoint(x: w, y: hInset + armH)
        )
        // Bottom edge of right arm, to inner notch.
        p.addLine(to: CGPoint(x: vInset + armW + innerR, y: hInset + armH))
        // INNER notch (bottom-right).
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW, y: hInset + armH + innerR),
            control: CGPoint(x: vInset + armW, y: hInset + armH)
        )
        // Right edge of bottom arm, to outer corner.
        p.addLine(to: CGPoint(x: vInset + armW, y: h - cornerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW - cornerR, y: h),
            control: CGPoint(x: vInset + armW, y: h)
        )
        // Bottom edge to outer corner of bottom arm.
        p.addLine(to: CGPoint(x: vInset + cornerR, y: h))
        p.addQuadCurve(
            to: CGPoint(x: vInset, y: h - cornerR),
            control: CGPoint(x: vInset, y: h)
        )
        // Left edge of bottom arm, to inner notch.
        p.addLine(to: CGPoint(x: vInset, y: hInset + armH + innerR))
        // INNER notch (bottom-left).
        p.addQuadCurve(
            to: CGPoint(x: vInset - innerR, y: hInset + armH),
            control: CGPoint(x: vInset, y: hInset + armH)
        )
        // Bottom edge of left arm.
        p.addLine(to: CGPoint(x: cornerR, y: hInset + armH))
        p.addQuadCurve(
            to: CGPoint(x: 0, y: hInset + armH - cornerR),
            control: CGPoint(x: 0, y: hInset + armH)
        )
        // Left edge up.
        p.addLine(to: CGPoint(x: 0, y: hInset + cornerR))
        p.addQuadCurve(
            to: CGPoint(x: cornerR, y: hInset),
            control: CGPoint(x: 0, y: hInset)
        )
        // Top edge of left arm, to inner notch.
        p.addLine(to: CGPoint(x: vInset - innerR, y: hInset))
        // INNER notch (top-left).
        p.addQuadCurve(
            to: CGPoint(x: vInset, y: hInset - innerR),
            control: CGPoint(x: vInset, y: hInset)
        )
        // Close back to starting point.
        p.closeSubpath()
        return p
    }
}

/// Layout math for one arm of the D-pad plus. Shared by the highlight
/// views so frame + corner radii stay in sync with `DPadPlusShape`.
private enum DPadArmGeometry {
    static let innerCornerRatio: CGFloat = 0.5

    static func frame(
        direction: DPadDirection, size: CGFloat, armFraction: CGFloat
    ) -> CGRect {
        let armW = size * armFraction
        let armH = size * armFraction
        let hInset = (size - armH) / 2
        let vInset = (size - armW) / 2
        let armLen = (size - armW) / 2
        switch direction {
        case .up:
            return CGRect(x: vInset, y: 0, width: armW, height: armLen)
        case .down:
            return CGRect(x: vInset, y: size - armLen, width: armW, height: armLen)
        case .left:
            return CGRect(x: 0, y: hInset, width: armLen, height: armH)
        case .right:
            return CGRect(x: size - armLen, y: hInset, width: armLen, height: armH)
        }
    }

    static func cornerRadii(
        direction: DPadDirection, size: CGFloat, armFraction: CGFloat,
        cornerFraction: CGFloat
    ) -> RectangleCornerRadii {
        let armW = size * armFraction
        let outerR = min(armW * cornerFraction, armW / 2)
        let innerR = outerR * innerCornerRatio
        switch direction {
        case .up:
            return RectangleCornerRadii(
                topLeading: outerR, bottomLeading: innerR,
                bottomTrailing: innerR, topTrailing: outerR)
        case .down:
            return RectangleCornerRadii(
                topLeading: innerR, bottomLeading: outerR,
                bottomTrailing: outerR, topTrailing: innerR)
        case .left:
            return RectangleCornerRadii(
                topLeading: outerR, bottomLeading: outerR,
                bottomTrailing: innerR, topTrailing: innerR)
        case .right:
            return RectangleCornerRadii(
                topLeading: innerR, bottomLeading: innerR,
                bottomTrailing: outerR, topTrailing: outerR)
        }
    }
}
