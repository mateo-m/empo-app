import Foundation

/// Pure touch-to-directions reducer for the on-screen D-pad: maps a
/// touch location in the D-pad's own square coordinate space to the
/// set of held directions and emits press / release edges for the
/// bits that changed. Framework-independent so the exact state
/// machine the app ships is what the Linux test suite exercises.
///
/// Geometry:
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
/// before ANY press. Callers must inject edges in array order so a
/// wedge transition never momentarily holds opposing directions.
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

    /// Directions currently held — the reducer's ONLY state. The
    /// host renders arm highlights from this and MUST have injected
    /// exactly these keys if it applied every returned edge in order.
    public private(set) var active: DirectionSet = []

    public init() {}

    /// Applies a touch-down or touch-move sample. `x`/`y` are in the
    /// D-pad's own coordinate space (center at `size/2`, +y down);
    /// `size` is the D-pad's bounding-box side length, passed per
    /// sample so a mid-session resize never leaves the reducer with
    /// stale geometry.
    public mutating func touchChanged(
        x: Double,
        y: Double,
        size: Double,
        deadZoneRatio: Double = defaultDeadZoneRatio,
        cardinalOnlyRadiusRatio: Double = defaultCardinalOnlyRadiusRatio,
        slideOffMargin: Double = defaultSlideOffMargin
    ) -> [Edge] {
        let radius = size / 2
        let dx = x - radius
        let dy = y - radius
        let distance = (dx * dx + dy * dy).squareRoot()

        // Slide-off: release everything but stay engaged. If the
        // finger comes back inside the D-pad, the next sample picks
        // up again.
        if distance > radius + slideOffMargin {
            return diff(to: [])
        }

        // Inner dead zone: don't emit events for tiny wobbles near
        // the center.
        if distance < radius * deadZoneRatio {
            return diff(to: [])
        }

        // atan2(dy, dx) with +y down means "up" is -y, an angle near
        // -pi/2.
        let angle = atan2(dy, dx)

        // Cardinal-only ring: too close to the pivot for diagonal
        // wedges to be trustworthy — resolve to the nearest main
        // direction.
        if distance < radius * cardinalOnlyRadiusRatio {
            return diff(to: DirectionSet(cardinalAngle: angle))
        }

        // Full 8-wedge angular mapping.
        return diff(to: DirectionSet(angle: angle))
    }

    /// Touch lifted or cancelled: releases every held direction.
    public mutating func touchEnded() -> [Edge] {
        diff(to: [])
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
