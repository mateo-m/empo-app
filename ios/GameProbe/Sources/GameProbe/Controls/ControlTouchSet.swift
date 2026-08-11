import Foundation

/// Tracks the touches that are live on ONE on-screen control, in the
/// order the fingers landed.
///
/// The control is "engaged" while at least one touch is live, so a
/// second finger on the same control neither restarts the sequence
/// nor ends it early: a button stays held until the last finger
/// lifts, and the D-pad keeps every finger it was given. Duplicate
/// begins and unknown ends are rejected, so the host emits its
/// touch-down and touch-up side effects exactly once each.
public struct ControlTouchSet<TouchID: Hashable & Sendable>: Sendable {
    /// The live touches, oldest first.
    public private(set) var live: [TouchID] = []

    public init() {}

    /// Whether any touch holds the control.
    public var isEngaged: Bool {
        !live.isEmpty
    }

    /// Whether move samples from `id` should be processed.
    public func isTracking(_ id: TouchID) -> Bool {
        live.contains(id)
    }

    /// Adds `id` to the control. Returns true when the control goes
    /// from idle to engaged — the caller emits its touch-down side
    /// effects on that true. A later finger, or a duplicate begin,
    /// returns false.
    public mutating func begin(_ id: TouchID) -> Bool {
        guard !live.contains(id) else { return false }
        live.append(id)
        return live.count == 1
    }

    /// What a lift did to the control. Hosts need both facts: whether
    /// the touch was live at all (forward it, or drop a duplicate
    /// end), and whether the control is idle now (release the key).
    public enum EndOutcome: Equatable, Sendable {
        /// The touch was never live here: emit nothing.
        case notTracked
        /// A finger lifted and others are still down.
        case stillEngaged
        /// The LAST finger lifted: the control is idle again.
        case idle
    }

    /// Removes `id` from the control, exactly once: a repeat end for
    /// the same finger reports `notTracked`, so touchesEnded and
    /// touchesCancelled arriving for one touch cannot release twice.
    public mutating func end(_ id: TouchID) -> EndOutcome {
        guard let index = live.firstIndex(of: id) else { return .notTracked }
        live.remove(at: index)
        return live.isEmpty ? .idle : .stillEngaged
    }

    /// Unconditionally abandons every live touch, for host-driven
    /// cancellation (the control was disabled or torn down
    /// mid-sequence and UIKit may never deliver the touches' ends).
    /// Returns the abandoned touches, oldest first, so the caller can
    /// close each one exactly as a real lift would.
    public mutating func reset() -> [TouchID] {
        let abandoned = live
        live.removeAll()
        return abandoned
    }
}

/// Hit-shape math for the on-screen controls, kept next to the touch
/// set so the capture layer stays free of testable logic.
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
