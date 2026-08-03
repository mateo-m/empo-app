import Foundation

/// Tracks the single touch an on-screen control follows for its
/// lifetime. The first touch to `begin` becomes the tracked touch;
/// every other touch is rejected until the tracked one ends, so a
/// stray second finger landing on the same control can neither
/// restart the sequence nor release it early. Multi-touch ACROSS
/// controls is unaffected — each control owns its own gate.
public struct SingleTouchGate<TouchID: Hashable & Sendable>: Sendable {
    public private(set) var tracked: TouchID?

    public init() {}

    /// Claims the gate for `id`. Returns true when `id` becomes the
    /// tracked touch, false when another touch already holds the gate
    /// (including `id` itself beginning twice).
    public mutating func begin(_ id: TouchID) -> Bool {
        guard tracked == nil else { return false }
        tracked = id
        return true
    }

    /// Whether move samples from `id` should be processed.
    public func isTracking(_ id: TouchID) -> Bool {
        tracked == id
    }

    /// Ends the sequence IF `id` is the tracked touch. Returns true
    /// when the gate was released (the caller should emit its
    /// touch-ended side effects exactly once, on that true).
    public mutating func end(_ id: TouchID) -> Bool {
        guard tracked == id else { return false }
        tracked = nil
        return true
    }

    /// Unconditionally abandons the tracked touch, for host-driven
    /// cancellation (the control was disabled or torn down
    /// mid-sequence and UIKit may never deliver the touch's end).
    /// Returns true when a touch was actually being tracked — the
    /// caller should emit its touch-ended side effects on that true,
    /// exactly as for `end`.
    public mutating func reset() -> Bool {
        guard tracked != nil else { return false }
        tracked = nil
        return true
    }
}

/// Hit-shape math for the on-screen controls, kept next to the gate
/// so the capture layer stays free of testable logic.
public enum ControlHitShape {
    /// Circular hit test matching SwiftUI's `.contentShape(Circle())`
    /// on a control frame: inside the circle inscribed in the
    /// `width` x `height` box (centered, diameter = the shorter
    /// side), boundary included. Corner touches outside the circle
    /// fall through to whatever is below the control.
    public static func circleContains(width: Double, height: Double, x: Double, y: Double) -> Bool {
        let radius = min(width, height) / 2
        let dx = x - width / 2
        let dy = y - height / 2
        return dx * dx + dy * dy <= radius * radius
    }
}
