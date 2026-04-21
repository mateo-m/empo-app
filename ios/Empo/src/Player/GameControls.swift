import SwiftUI

/// On-screen action button and D-pad, rendered with SwiftUI + the
/// Liquid Glass material.
///
/// Touch-dispatch semantics:
///   - `mkxp_injectKeyEvent(scancode, 1)` on press-down,
///     `mkxp_injectKeyEvent(scancode, 0)` on release.
///   - Action button: slide-off does NOT release the key.
///   - D-pad: 8-wedge angular mapping, bitwise diff across moves,
///     inner 20% dead zone, slide-off at radius+30pt releases all
///     directions without cancelling the gesture.
///   - Edit mode blocks input entirely (the parent's drag gesture
///     wins for repositioning).
///   - Explicit release-all on disappear / edit-mode transition so
///     keys never get stuck at the engine when SwiftUI reclaims the
///     view or the user enters edit mode mid-press.

// MARK: - Action button

/// Circular glass button. Presses emit a down/up event pair through
/// `mkxp_injectKeyEvent`. Holding and sliding the finger off the
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
        // itself; a matching scaleEffect on the whole ZStack ensures
        // the label scales together with the glass (the interactive
        // modifier alone only scales the glass layer, not content
        // drawn on top of it).
        ZStack {
            // Fill the Circle with .clear before applying the glass
            // effect, so the material isn't compositing against the
            // shape's default foreground fill. Matches the D-pad's
            // plus shape treatment so both controls render the same
            // glass brightness.
            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)
            Text(label)
                .font(.system(size: size < 60 ? 12 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
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
        // Touch dispatch. minimumDistance=0 makes this a press-tracking
        // gesture that fires on touch-down (not after a drag threshold).
        // Only install when NOT editing so the parent's drag-to-reposition
        // gesture wins in edit mode.
        .gesture(editing ? nil : pressGesture)
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

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressed {
                    isPressed = true
                    Haptics.controllerTap()
                    mkxp_injectKeyEvent(scancode, 1)
                }
            }
            .onEnded { _ in
                releaseIfHeld()
            }
    }

    private func releaseIfHeld() {
        guard isPressed else { return }
        isPressed = false
        mkxp_injectKeyEvent(scancode, 0)
    }
}


// MARK: - D-pad

/// Eight-wedge D-pad rendered as a physical-looking rounded plus
/// shape. The four arms are individual glass surfaces that brighten
/// when their direction is active; a small center dot marks the
/// pivot (and the dead zone).
///
/// Diagonals press two scancodes at once; the bitwise diff across
/// `onChanged` ticks means holding steady emits zero events and a
/// straight slide from NE to SE releases UP and presses DOWN while
/// leaving RIGHT held throughout (no stutter).
///
/// The hit-test shape is a full circle that inscribes the plus
/// outline, so touches in the outer "corners" between arms still
/// engage (the angular wedge map decides which direction they
/// represent). This keeps hit-testing lenient even with a visually
/// spare plus silhouette.
struct DPad: View {
    let size: CGFloat
    let editing: Bool

    @State private var activeDirections: DPadDirectionSet = []

    /// Once the finger drags more than `slideOffMargin` past the D-pad
    /// edge we release all directions but keep the gesture alive so
    /// sliding back in re-engages.
    @State private var slideOff: Bool = false

    private var radius: CGFloat { size / 2 }

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
    /// a subtle fillet; 0 keeps the notches perfectly square.
    private let innerCornerFraction: CGFloat = 0.1

    var body: some View {
        let plus = DPadPlusShape(
            armFraction: armFraction,
            cornerFraction: cornerFraction,
            innerCornerFraction: innerCornerFraction
        )

        let pressed = !activeDirections.isEmpty

        // Everything here lives inside a single scaled ZStack so the
        // glass plus, per-arm highlights, chevrons, and center dot all
        // spring together on press. Highlights are clipped to the
        // plus silhouette so their rounded outer corners don't spill
        // past the arm tips. The gradient UnitPoints are expressed
        // in the D-pad's full bounding box (not the arm's local rect)
        // because SwiftUI resolves `.fill(LinearGradient(...))` on a
        // Shape against the Shape's full frame.
        ZStack {
            // Base glass: transparent-fill plus so the material isn't
            // compositing against the shape's default foreground;
            // matches the action button's Circle treatment so both
            // controls render the same glass brightness.
            plus
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: plus)

            // Per-arm active highlights, clipped to the plus outline.
            ZStack {
                ForEach(DPadDirection.allCases, id: \.self) { dir in
                    DPadArmHighlight(direction: dir, armFraction: armFraction, cornerFraction: cornerFraction)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0)],
                                startPoint: dir.highlightGradientStart,
                                endPoint: dir.highlightGradientEnd(armFraction: armFraction)
                            )
                        )
                        .opacity(activeDirections.contains(dir) ? 1 : 0)
                        .animation(Motion.instant, value: activeDirections)
                }
            }
            .clipShape(plus)

            // Chevrons, one in the center of each arm.
            ForEach(DPadDirection.allCases, id: \.self) { dir in
                Image(systemName: dir.symbolName)
                    .font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundStyle(.white.opacity(activeDirections.contains(dir) ? 1.0 : 0.55))
                    .offset(dir.glyphOffset(size: size, armFraction: armFraction))
            }

            // Center dot.
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        // Scale the whole stack on press so glass, highlights,
        // chevrons, and the center dot all spring together. `.interactive()`
        // alone scales only the glass layer; this keeps everything
        // visually coherent including the highlights' clip against
        // the plus silhouette.
        .scaleEffect(pressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: pressed)
        // Force the dark Liquid Glass variant so the plus clip shape
        // doesn't render noticeably brighter than the action buttons'
        // circles. With the default (system) color scheme, iOS 26's
        // glass material resolves differently on a concave clip (our
        // plus) than on a convex clip (our action-button circles),
        // which showed up in dark gameplay scenes as a near-white
        // D-pad next to translucent-dark action buttons. Pinning to
        // .dark here locks the material in one mode and keeps the
        // two visually consistent.
        .darkGlass()
        // Hit-test the full bounding circle so slightly imprecise
        // presses (between arms, just outside the plus shape) still
        // engage. The wedge math in updateDirections decides which
        // direction a given touch point represents.
        .contentShape(Circle())
        .gesture(editing ? nil : dpadGesture)
        .onChange(of: editing) { _, newValue in
            if newValue {
                releaseAll()
            }
        }
        .onDisappear {
            releaseAll()
        }
    }

    private var dpadGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateDirections(at: value.location)
            }
            .onEnded { _ in
                releaseAll()
                slideOff = false
            }
    }

    private func updateDirections(at location: CGPoint) {
        // DragGesture.location is in the gesture's view space, so the
        // view's own center is at (size/2, size/2). Compute the offset
        // from center to map the touch into our directional wedges.
        let cx = radius
        let cy = radius
        let dx = location.x - cx
        let dy = location.y - cy
        let distance = sqrt(dx * dx + dy * dy)

        // Slide-off: release everything but stay engaged. If the user
        // drags their thumb back inside the D-pad, we pick up again on
        // the next onChanged.
        if distance > radius + DPadConstants.slideOffMargin {
            if !slideOff {
                slideOff = true
                diffAndEmit(newSet: [])
            }
            return
        }
        slideOff = false

        // Inner dead zone. The UIKit impl used 20% of radius to avoid
        // sending events for tiny wobbles near the center.
        let deadZone = radius * DPadConstants.deadZoneRatio
        if distance < deadZone {
            diffAndEmit(newSet: [])
            return
        }

        // 8-wedge angular mapping with pi/8 thresholds. The UIKit impl
        // uses atan2 with the same math; we port it verbatim.
        // atan2(dy, dx) in SwiftUI's view coordinate space has +y down,
        // so "up" is -y which corresponds to an angle near -pi/2.
        let angle = atan2(dy, dx)
        let newSet = DPadDirectionSet(angle: angle)
        diffAndEmit(newSet: newSet)
    }

    /// Diff `newSet` against the current `activeDirections` and emit
    /// up/down events for ONLY the bits that changed. Holding a
    /// direction steady emits zero events. Fires a haptic tap when a
    /// new direction enters the active set (one buzz per wedge
    /// transition rather than one continuous buzz while held).
    private func diffAndEmit(newSet: DPadDirectionSet) {
        if newSet == activeDirections { return }
        let toRelease = activeDirections.subtracting(newSet)
        let toPress = newSet.subtracting(activeDirections)
        toRelease.forEach { mkxp_injectKeyEvent($0.scancode, 0) }
        toPress.forEach   { mkxp_injectKeyEvent($0.scancode, 1) }
        if !toPress.isEmpty {
            Haptics.controllerTap()
        }
        activeDirections = newSet
    }

    private func releaseAll() {
        activeDirections.forEach { mkxp_injectKeyEvent($0.scancode, 0) }
        activeDirections = []
    }
}


// MARK: - D-pad supporting types

private enum DPadConstants {
    static let slideOffMargin: CGFloat = 30
    static let deadZoneRatio: CGFloat = 0.2
}

enum DPadDirection: CaseIterable, Hashable {
    case up, down, left, right

    var scancode: Int32 {
        switch self {
        case .up:    Int32(MKXP_SCANCODE_UP)
        case .down:  Int32(MKXP_SCANCODE_DOWN)
        case .left:  Int32(MKXP_SCANCODE_LEFT)
        case .right: Int32(MKXP_SCANCODE_RIGHT)
        }
    }

    var symbolName: String {
        switch self {
        case .up:    "chevron.up"
        case .down:  "chevron.down"
        case .left:  "chevron.left"
        case .right: "chevron.right"
        }
    }

    /// Offset from the center of the D-pad at which to draw the
    /// chevron for this direction. Centered within the arm's outer
    /// rectangle: the arm spans `armLen = (size - armW) / 2` from
    /// the outer edge to the center-square edge, so its midpoint is
    /// at `armLen/2` from the outer edge, which is `size/2 - armLen/2
    /// = (size + armW) / 4` from the D-pad center. That offset puts
    /// the chevron in the visual center of each arm, not near the tip.
    func glyphOffset(size: CGFloat, armFraction: CGFloat) -> CGSize {
        let d = (size + size * armFraction) / 4
        switch self {
        case .up:    return CGSize(width: 0, height: -d)
        case .down:  return CGSize(width: 0, height: d)
        case .left:  return CGSize(width: -d, height: 0)
        case .right: return CGSize(width: d, height: 0)
        }
    }

    /// Gradient start/end points used to fade the arm highlight from
    /// full opacity at the outer tip to transparent at the inner edge
    /// (where the arm meets the center square).
    ///
    /// Points are in UnitPoint space of the FULL D-pad bounding box
    /// (not the arm's local rect), because SwiftUI's
    /// `.fill(LinearGradient(...))` resolves UnitPoints against the
    /// shape's full frame. Our `DPadArmHighlight` shape receives
    /// the D-pad rect and draws a path inside one arm, so the
    /// gradient must be sized to cover only the arm's extent to
    /// be visible; `.top` -> `.bottom` across the full D-pad would
    /// show only a shallow falloff within the arm.
    ///
    /// The arm's outer tip is at the D-pad's edge (0 or 1 along its
    /// axis), and its inner edge is at the center-square boundary,
    /// which in UnitPoints is `(1 - armFraction) / 2` from the
    /// outer edge.
    var highlightGradientStart: UnitPoint {
        switch self {
        case .up:    return UnitPoint(x: 0.5, y: 0)
        case .down:  return UnitPoint(x: 0.5, y: 1)
        case .left:  return UnitPoint(x: 0,   y: 0.5)
        case .right: return UnitPoint(x: 1,   y: 0.5)
        }
    }
    func highlightGradientEnd(armFraction: CGFloat) -> UnitPoint {
        let armLenFrac = (1 - armFraction) / 2
        switch self {
        case .up:    return UnitPoint(x: 0.5,             y: armLenFrac)
        case .down:  return UnitPoint(x: 0.5,             y: 1 - armLenFrac)
        case .left:  return UnitPoint(x: armLenFrac,      y: 0.5)
        case .right: return UnitPoint(x: 1 - armLenFrac,  y: 0.5)
        }
    }
}

/// Bitset-style container for direction state. Supports OR
/// composition so angular mapping can return "up | right" for
/// diagonal input.
struct DPadDirectionSet: OptionSet {
    let rawValue: UInt8

    static let up    = DPadDirectionSet(rawValue: 1 << 0)
    static let down  = DPadDirectionSet(rawValue: 1 << 1)
    static let left  = DPadDirectionSet(rawValue: 1 << 2)
    static let right = DPadDirectionSet(rawValue: 1 << 3)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Build a direction set from an atan2 angle (radians, -pi to pi,
    /// +y down as in SwiftUI's coordinate system). Produces cardinal
    /// or diagonal pairs based on pi/8 wedge thresholds.
    init(angle: Double) {
        // Normalize to [0, 2pi).
        let a = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        // The 8 wedges, each pi/4 wide, centered on the cardinal and
        // diagonal directions. Using >= on the low edge and < on the
        // high edge keeps transitions deterministic at exactly pi/8.
        let s = Double.pi / 8
        switch a {
        case (15 * s)..<(2 * .pi), 0..<s:       self = .right
        case s..<(3 * s):                        self = [.right, .down]
        case (3 * s)..<(5 * s):                  self = .down
        case (5 * s)..<(7 * s):                  self = [.down, .left]
        case (7 * s)..<(9 * s):                  self = .left
        case (9 * s)..<(11 * s):                 self = [.left, .up]
        case (11 * s)..<(13 * s):                self = .up
        case (13 * s)..<(15 * s):                self = [.up, .right]
        default:                                 self = []
        }
    }

    /// Check whether a logical `DPadDirection` is currently set.
    /// Routes to the underlying OptionSet flag member for that
    /// direction.
    func contains(_ direction: DPadDirection) -> Bool {
        switch direction {
        case .up:    return rawValue & DPadDirectionSet.up.rawValue != 0
        case .down:  return rawValue & DPadDirectionSet.down.rawValue != 0
        case .left:  return rawValue & DPadDirectionSet.left.rawValue != 0
        case .right: return rawValue & DPadDirectionSet.right.rawValue != 0
        }
    }

    /// Iterate over set directions, for use with `for dir in set`.
    func forEach(_ body: (DPadDirection) -> Void) {
        if contains(.up)    { body(.up) }
        if contains(.down)  { body(.down) }
        if contains(.left)  { body(.left) }
        if contains(.right) { body(.right) }
    }
}


// MARK: - D-pad decorative shapes

/// Rounded plus silhouette that forms the D-pad's base. Built as a
/// single closed polygon (no overlapping sub-paths), so there are no
/// internal seams where two rectangles used to meet. The 8 outer
/// corners are rounded by `cornerFraction`; the 4 inner corners
/// (the notches between arms) are filleted by `innerCornerFraction`
/// with a concave arc for a friendlier silhouette.
///
/// `armFraction` is the width of each arm as a fraction of the
/// bounding box. 0.3 - 0.4 gives a balanced "plus" feel; below that
/// it starts to look spindly, above that the arms merge into a
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
        let vInset = (rect.width - armW) / 2   // x of vertical bar left
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

/// Highlight fill for one arm of the plus. Rectangle fitted inside
/// the arm with asymmetric corner rounding: outer corners match the
/// plus shape's arm-tip radius, while inner corners (against the
/// center square) use a smaller radius so the highlight visually
/// settles into the arm rather than mirroring the tip.
private struct DPadArmHighlight: Shape {
    let direction: DPadDirection
    let armFraction: CGFloat
    let cornerFraction: CGFloat

    /// Fraction of the outer corner radius to use for the inner
    /// corners. 0.5 gives a subtle "less rounded" look; 0 would be
    /// sharp inner corners (matches the plus's sharp inner edges).
    private static let innerRatio: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let armW = rect.width * armFraction
        let armH = rect.height * armFraction
        let outerR = min(armW * cornerFraction, armW / 2, armH / 2)
        let innerR = outerR * Self.innerRatio
        let hInset = (rect.height - armH) / 2
        let vInset = (rect.width - armW) / 2
        // The arm spans from the outer edge of the bounding box to
        // the edge of the center square (armLen long). Do NOT extend
        // into the center square - that would cover the center dot
        // and visually bleed into the orthogonal arms.
        let armLen = (rect.width - armW) / 2

        let armRect: CGRect
        let radii: RectangleCornerRadii
        switch direction {
        case .up:
            // Top arm: rounded top (outer) corners, less-rounded
            // bottom (inner) corners.
            armRect = CGRect(x: vInset, y: 0, width: armW, height: armLen)
            radii = RectangleCornerRadii(
                topLeading: outerR,
                bottomLeading: innerR,
                bottomTrailing: innerR,
                topTrailing: outerR
            )
        case .down:
            armRect = CGRect(x: vInset, y: rect.height - armLen, width: armW, height: armLen)
            radii = RectangleCornerRadii(
                topLeading: innerR,
                bottomLeading: outerR,
                bottomTrailing: outerR,
                topTrailing: innerR
            )
        case .left:
            armRect = CGRect(x: 0, y: hInset, width: armLen, height: armH)
            radii = RectangleCornerRadii(
                topLeading: outerR,
                bottomLeading: outerR,
                bottomTrailing: innerR,
                topTrailing: innerR
            )
        case .right:
            armRect = CGRect(x: rect.width - armLen, y: hInset, width: armLen, height: armH)
            radii = RectangleCornerRadii(
                topLeading: innerR,
                bottomLeading: innerR,
                bottomTrailing: outerR,
                topTrailing: outerR
            )
        }
        return UnevenRoundedRectangle(cornerRadii: radii).path(in: armRect)
    }
}
