import Foundation

/// Reducer tuning for the joystick style. The stick reuses
/// `DPadTouchReducer` per sample; only these constants differ from
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
}
