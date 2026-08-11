import Foundation

/// Pure touch-to-directions reducer for the on-screen D-pad: maps the
/// touches on the D-pad, in its own square coordinate space, to the
/// set of held directions and emits press / release edges for the
/// bits that changed. Framework-independent so the exact state
/// machine the app ships is what the Linux test suite exercises.
///
/// Multi-touch: the pad holds the UNION of what each live touch
/// resolves to, like a physical D-pad under two thumbs. Hold the
/// right arm, put a second finger on the down arm, and the pad reads
/// down+right; lift the right finger and DOWN stays held, with no
/// need to lift the second finger and press again. Each touch keeps
/// its own dead zone, ring and slide-off state, so one finger sliding
/// off releases only what that finger held.
///
/// Geometry (per touch):
///   - 8-wedge angular map with pi/8 thresholds (cardinals plus
///     two-direction diagonals), ported verbatim from the UIKit-era
///     implementation.
///   - Inner dead zone at `deadZoneRatio` of the radius so tiny
///     wobbles near the pivot emit nothing.
///   - Cardinal-only ring between the dead zone and
///     `cardinalOnlyRadiusRatio` of the radius: touches there
///     resolve to the nearest of the four main directions, never a
///     diagonal. Close to the pivot a few points of thumb wobble is
///     tens of degrees of angle, and an accidental diagonal is not
///     benign — RGSS `Input.dir4` switches to the OTHER held
///     direction, so grazing a diagonal wedge steers a 4-way game
///     sideways. Deliberate diagonals pressed out on the pad are
///     unaffected. (PPSSPP's D-pad and Lemuroid's RadialGamePad
///     ship the same guard.)
///   - Slide-off: past `radius + slideOffMargin` every direction
///     releases, but the touch stays engaged so sliding back inside
///     re-presses. The release batch emits once — the diff against
///     `active` swallows repeats while the finger stays parked
///     beyond the edge.
///
/// Edge-order contract: every returned array lists ALL releases
/// before ANY press. Callers must inject edges in array order so one
/// finger moving between wedges never momentarily holds opposing
/// directions. Two fingers on opposite arms DO hold both, exactly as
/// a keyboard does with two arrow keys down; the game decides what
/// that means.
///
/// Stuck-key contract: a direction is held only while a live touch
/// resolves to it, so the host MUST report every lift. Where UIKit
/// can drop a touch end (the control was disabled, detached, or the
/// touch vanished from the event), the host closes that touch
/// itself — see `ControlTouchSet` and the capture layer.
public struct DPadTouchReducer: Sendable {
    public enum Direction: CaseIterable, Hashable, Sendable {
        case up, down, left, right
    }

    /// Bitset-style container for direction state. Supports OR
    /// composition so the angular map can return "up | right" for
    /// diagonal input.
    public struct DirectionSet: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public static let up = DirectionSet(rawValue: 1 << 0)
        public static let down = DirectionSet(rawValue: 1 << 1)
        public static let left = DirectionSet(rawValue: 1 << 2)
        public static let right = DirectionSet(rawValue: 1 << 3)

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Build a direction set from an atan2 angle (radians, -pi to
        /// pi, +y down as in view coordinate space). Produces cardinal
        /// or diagonal pairs based on pi/8 wedge thresholds.
        public init(angle: Double) {
            // Normalize to [0, 2pi).
            let a = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            // The 8 wedges, each pi/4 wide, centered on the cardinal
            // and diagonal directions. Using >= on the low edge and <
            // on the high edge keeps transitions deterministic at
            // exactly pi/8.
            let s = Double.pi / 8
            switch a {
            case (15 * s)..<(2 * .pi), 0..<s: self = .right
            case s..<(3 * s): self = [.right, .down]
            case (3 * s)..<(5 * s): self = .down
            case (5 * s)..<(7 * s): self = [.down, .left]
            case (7 * s)..<(9 * s): self = .left
            case (9 * s)..<(11 * s): self = [.left, .up]
            case (11 * s)..<(13 * s): self = .up
            case (13 * s)..<(15 * s): self = [.up, .right]
            default: self = []
            }
        }

        /// Build a cardinal-only set from an atan2 angle: the nearest
        /// of the four main directions, with pi/4 boundaries. Same
        /// normalization (and the same exact-boundary ulp caveat) as
        /// `init(angle:)`.
        public init(cardinalAngle angle: Double) {
            let a = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let s = Double.pi / 4
            switch a {
            case (7 * s)..<(2 * .pi), 0..<s: self = .right
            case s..<(3 * s): self = .down
            case (3 * s)..<(5 * s): self = .left
            case (5 * s)..<(7 * s): self = .up
            default: self = []
            }
        }

        /// Check whether a logical `Direction` is currently set.
        /// Routes to the underlying OptionSet flag member for that
        /// direction.
        public func contains(_ direction: Direction) -> Bool {
            switch direction {
            case .up: return rawValue & DirectionSet.up.rawValue != 0
            case .down: return rawValue & DirectionSet.down.rawValue != 0
            case .left: return rawValue & DirectionSet.left.rawValue != 0
            case .right: return rawValue & DirectionSet.right.rawValue != 0
            }
        }

        /// Member directions in the fixed emission order (up, down,
        /// left, right) so edge arrays are deterministic.
        public var directions: [Direction] {
            Direction.allCases.filter { contains($0) }
        }
    }

    public struct Edge: Equatable, Sendable {
        public let direction: Direction
        public let pressed: Bool

        public init(direction: Direction, pressed: Bool) {
            self.direction = direction
            self.pressed = pressed
        }
    }

    public static let defaultDeadZoneRatio = 0.2
    public static let defaultCardinalOnlyRadiusRatio = 0.5
    public static let defaultSlideOffMargin = 30.0

    /// Directions currently held: the union over every live touch.
    /// The host renders arm highlights from this and MUST have
    /// injected exactly these keys if it applied every returned edge
    /// in order.
    public private(set) var active: DirectionSet = []

    /// One entry per live touch, in the order the fingers landed.
    private struct Touch {
        let id: Int
        var x: Double
        var y: Double
        var directions: DirectionSet
    }

    private var touches: [Touch] = []

    public init() {}

    /// Sample point of the OLDEST live touch, or nil while no finger
    /// is down. The joystick nub follows it: with two fingers on the
    /// pad the nub stays with the one that started the movement
    /// instead of jumping between them.
    public var leadTouchPoint: (x: Double, y: Double)? {
        touches.first.map { ($0.x, $0.y) }
    }

    /// Applies a touch-down or touch-move sample for the touch `id`.
    /// `x`/`y` are in the D-pad's own coordinate space (center at
    /// `size/2`, +y down); `size` is the D-pad's bounding-box side
    /// length, passed per sample so a mid-session resize never leaves
    /// the reducer with stale geometry. An unknown `id` joins the
    /// pad; a known one replaces its previous sample.
    public mutating func touchChanged(
        touch id: Int,
        x: Double,
        y: Double,
        size: Double,
        deadZoneRatio: Double = defaultDeadZoneRatio,
        cardinalOnlyRadiusRatio: Double = defaultCardinalOnlyRadiusRatio,
        slideOffMargin: Double = defaultSlideOffMargin
    ) -> [Edge] {
        let directions = Self.directions(
            x: x, y: y, size: size,
            deadZoneRatio: deadZoneRatio,
            cardinalOnlyRadiusRatio: cardinalOnlyRadiusRatio,
            slideOffMargin: slideOffMargin
        )
        let touch = Touch(id: id, x: x, y: y, directions: directions)
        if let index = touches.firstIndex(where: { $0.id == id }) {
            touches[index] = touch
        } else {
            touches.append(touch)
        }
        return diff(to: union)
    }

    /// Same sample, with the thresholds a movement style supplies.
    public mutating func touchChanged(
        touch id: Int,
        x: Double,
        y: Double,
        size: Double,
        tuning: MovementTuning
    ) -> [Edge] {
        touchChanged(
            touch: id, x: x, y: y, size: size,
            deadZoneRatio: tuning.deadZoneRatio,
            cardinalOnlyRadiusRatio: tuning.cardinalOnlyRadiusRatio,
            slideOffMargin: tuning.slideOffMargin
        )
    }

    /// One touch lifted or cancelled: releases the directions only
    /// that finger held. Directions another finger still holds stay
    /// pressed, with no release / press stutter. An unknown `id` is
    /// silent.
    public mutating func touchEnded(touch id: Int) -> [Edge] {
        guard let index = touches.firstIndex(where: { $0.id == id }) else { return [] }
        touches.remove(at: index)
        return diff(to: union)
    }

    /// Host-driven cancellation (the control was disabled or torn
    /// down mid-touch): drops every touch and releases every held
    /// direction.
    public mutating func releaseAll() -> [Edge] {
        touches.removeAll()
        return diff(to: [])
    }

    /// What the pad holds: the union over the live touches.
    private var union: DirectionSet {
        touches.reduce(into: DirectionSet()) { $0.formUnion($1.directions) }
    }

    /// The directions ONE touch at `(x, y)` resolves to. Pure
    /// geometry: no state, so each finger is mapped independently.
    static func directions(
        x: Double,
        y: Double,
        size: Double,
        deadZoneRatio: Double,
        cardinalOnlyRadiusRatio: Double,
        slideOffMargin: Double
    ) -> DirectionSet {
        let radius = size / 2
        let dx = x - radius
        let dy = y - radius
        let distance = (dx * dx + dy * dy).squareRoot()

        // Slide-off: this finger releases but stays engaged. If it
        // comes back inside the D-pad, its next sample picks up again.
        if distance > radius + slideOffMargin {
            return []
        }

        // Inner dead zone: don't emit events for tiny wobbles near
        // the center.
        if distance < radius * deadZoneRatio {
            return []
        }

        // atan2(dy, dx) with +y down means "up" is -y, an angle near
        // -pi/2.
        let angle = atan2(dy, dx)

        // Cardinal-only ring: too close to the pivot for diagonal
        // wedges to be trustworthy — resolve to the nearest main
        // direction.
        if distance < radius * cardinalOnlyRadiusRatio {
            return DirectionSet(cardinalAngle: angle)
        }

        // Full 8-wedge angular mapping.
        return DirectionSet(angle: angle)
    }

    /// Diff `newSet` against `active` and emit edges for ONLY the
    /// bits that changed, releases before presses. Holding a
    /// direction steady emits zero edges.
    private mutating func diff(to newSet: DirectionSet) -> [Edge] {
        guard newSet != active else { return [] }
        let released = active.subtracting(newSet).directions
        let pressed = newSet.subtracting(active).directions
        active = newSet
        return released.map { Edge(direction: $0, pressed: false) }
            + pressed.map { Edge(direction: $0, pressed: true) }
    }
}
