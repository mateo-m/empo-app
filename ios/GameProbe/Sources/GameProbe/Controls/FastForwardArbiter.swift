import Foundation

/// Pure arbitration for the fast-forward actions. The host owns the
/// engine bridge; this type only decides what to write to it.
///
/// Rules (plan: layout-profiles-pr1):
/// - Every event derives the next state from the supplied bridge
///   multiplier, never from cached state alone.
/// - A latched toggle wins over a hold release.
/// - `configuredMultiplier == nil` means the game has fast forward
///   turned off. Every event is inert then.
public struct FastForwardArbiter: Equatable, Sendable {
    public private(set) var holdCount: Int = 0
    public private(set) var latched: Bool = false

    public init() {}

    /// The multiplier to write to the bridge, or nil for no write.
    public typealias Write = Int?

    public mutating func holdPressed(
        configuredMultiplier: Int?,
        bridgeMultiplier: Int
    ) -> Write {
        guard let configured = configuredMultiplier, configured >= 2 else { return nil }
        holdCount += 1
        return configured
    }

    public mutating func holdReleased(
        configuredMultiplier: Int?,
        bridgeMultiplier: Int
    ) -> Write {
        guard holdCount > 0 else { return nil }
        holdCount -= 1
        if holdCount > 0 { return nil }
        if latched {
            // Latch wins: keep the configured speed after the hold ends.
            guard let configured = configuredMultiplier, configured >= 2 else {
                latched = false
                return 1
            }
            return configured
        }
        return 1
    }

    public mutating func toggled(
        configuredMultiplier: Int?,
        bridgeMultiplier: Int
    ) -> Write {
        guard let configured = configuredMultiplier, configured >= 2 else {
            latched = false
            return bridgeMultiplier > 1 ? 1 : nil
        }
        if holdCount > 0 {
            // Toggling during a hold arms or disarms the latch. The
            // speed stays on either way while the hold lasts.
            latched.toggle()
            return configured
        }
        // No hold: the bridge is the truth for "is it on now".
        let bridgeActive = bridgeMultiplier > 1
        latched = !bridgeActive
        return latched ? configured : 1
    }

    /// Explicit latch-off (a stateful Toggle set to OFF). During a
    /// hold the speed stays up (the hold owns it); with no hold a
    /// running engine stops.
    public mutating func latchCleared(bridgeMultiplier: Int) -> Write {
        latched = false
        if holdCount > 0 { return nil }
        return bridgeMultiplier > 1 ? 1 : nil
    }

    /// Fires when the host must drop every hold at once (input
    /// suppression, session stop, scene teardown).
    public mutating func releaseAllHolds(
        configuredMultiplier: Int?,
        bridgeMultiplier: Int
    ) -> Write {
        guard holdCount > 0 else { return nil }
        holdCount = 0
        if latched {
            guard let configured = configuredMultiplier, configured >= 2 else {
                latched = false
                return 1
            }
            return configured
        }
        return 1
    }

    public struct ReconcileOutcome: Equatable, Sendable {
        /// The multiplier to write, or nil for no write.
        public var write: Int?
        /// Whether fast forward counts as active after reconciling.
        public var active: Bool

        public init(write: Int?, active: Bool) {
            self.write = write
            self.active = active
        }
    }

    /// Adopts the bridge state at a safe point (session start, resume,
    /// sheet open). While a hold is active the arbiter keeps its own
    /// state: adopting mid-hold would convert the hold into a latch.
    public mutating func reconcile(
        configuredMultiplier: Int?,
        bridgeMultiplier: Int
    ) -> ReconcileOutcome {
        if holdCount > 0 {
            return ReconcileOutcome(write: nil, active: bridgeMultiplier > 1)
        }
        let bridgeActive = bridgeMultiplier > 1
        guard let configured = configuredMultiplier, configured >= 2 else {
            latched = false
            // Settings turned fast forward off. Stop a running engine.
            return ReconcileOutcome(write: bridgeActive ? 1 : nil, active: false)
        }
        latched = bridgeActive
        // Push the configured value back so an in-pause settings edit
        // (4x -> 2x) takes effect on resume.
        return ReconcileOutcome(
            write: bridgeActive ? configured : nil,
            active: bridgeActive
        )
    }
}
