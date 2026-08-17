import Foundation

/// The reducer thresholds one movement style samples with. The host
/// asks its style for these instead of branching per style around the
/// `touchChanged` call, so the style -> numbers mapping lives here
/// with the numbers themselves.
public struct MovementTuning: Equatable, Sendable {
    public let deadZoneRatio: Double
    public let cardinalOnlyRadiusRatio: Double
    public let slideOffMargin: Double

    public init(deadZoneRatio: Double, cardinalOnlyRadiusRatio: Double, slideOffMargin: Double) {
        self.deadZoneRatio = deadZoneRatio
        self.cardinalOnlyRadiusRatio = cardinalOnlyRadiusRatio
        self.slideOffMargin = slideOffMargin
    }
}

extension MovementStyle {
    /// Thresholds for a control of this style, `size` points across.
    public func tuning(size: Double) -> MovementTuning {
        switch self {
        case .dpad:
            return MovementTuning(
                deadZoneRatio: DPadTouchReducer.defaultDeadZoneRatio,
                cardinalOnlyRadiusRatio: DPadTouchReducer.defaultCardinalOnlyRadiusRatio,
                slideOffMargin: DPadTouchReducer.defaultSlideOffMargin
            )
        case .stick:
            return MovementTuning(
                deadZoneRatio: MovementStickTuning.deadZoneRatio,
                cardinalOnlyRadiusRatio: MovementStickTuning.cardinalOnlyRadiusRatio,
                slideOffMargin: MovementStickTuning.slideOffMargin(size: size)
            )
        }
    }
}

/// Reducer tuning for the joystick style. The stick reuses
/// `DPadTouchReducer` per sample. Only these constants differ from
/// the d-pad defaults.
///
/// - The cardinal-only ring shrinks to 0.3: a visible follow-nub
///   invites small deliberate diagonals, and the d-pad's wide guard
///   reads as a broken stick.
/// - The slide-off margin scales with the radius. The d-pad's fixed
///   30pt is 60% of a small pad but disappears on a large stick.
public enum MovementStickTuning {
    public static let deadZoneRatio = DPadTouchReducer.defaultDeadZoneRatio
    public static let cardinalOnlyRadiusRatio = 0.3
    public static let slideOffMarginRatio = 0.6

    public static func slideOffMargin(size: Double) -> Double {
        size / 2 * slideOffMarginRatio
    }

    /// Thumb nub diameter as a fraction of the stick size. Tuning,
    /// not decoration: it decides the nub's travel radius below.
    public static let nubRatio = 0.42

    /// Clamped nub offset from the stick center for a touch at
    /// `(x, y)` in the stick's local space. The nub tracks the
    /// finger and stops where its rim meets the base circle's rim.
    public static func thumbOffset(
        x: Double, y: Double, size: Double
    ) -> (dx: Double, dy: Double) {
        let radius = size / 2
        let dx = x - radius
        let dy = y - radius
        let travel = radius - (size * nubRatio) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > travel, distance > 0 else { return (dx, dy) }
        let scale = travel / distance
        return (dx * scale, dy * scale)
    }
}
