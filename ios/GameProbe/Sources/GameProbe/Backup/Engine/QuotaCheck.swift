import Foundation

/// The room a target has for this run, per SPEC 5.14.
///
/// Where the provider answers a space query, the engine checks
/// before staging and refuses a run that cannot fit, naming the
/// shortfall. Where no query exists, the limit comes from the first
/// upload error, and the same ladder runs either way.
///
/// Quota pressure never touches a namespace this device does not
/// own. That is invariant 8, and nothing here names a namespace.
public enum QuotaCheck {

    /// What a refused run reports.
    public struct Shortfall: Equatable, Sendable {
        /// What the run would upload.
        public var neededBytes: Int64
        /// What the target has left, under the smaller of its own
        /// limit and the target's cap.
        public var freeBytes: Int64

        public init(neededBytes: Int64, freeBytes: Int64) {
            self.neededBytes = neededBytes
            self.freeBytes = freeBytes
        }

        public var missingBytes: Int64 {
            max(0, neededBytes - freeBytes)
        }
    }

    /// The limit that governs, which is the smaller of the target's
    /// own limit and the optional cap of 5.14. `nil` where neither
    /// states a number.
    public static func effectiveLimit(reading: QuotaReading?, capBytes: Int64?) -> Int64? {
        switch (reading?.limitBytes, capBytes) {
        case (let limit?, let cap?): return min(limit, cap)
        case (let limit?, nil): return limit
        case (nil, let cap?): return cap
        case (nil, nil): return nil
        }
    }

    /// What the target has left, or `nil` where no number governs.
    public static func freeBytes(reading: QuotaReading?, capBytes: Int64?) -> Int64? {
        guard let reading, let limit = effectiveLimit(reading: reading, capBytes: capBytes) else {
            return nil
        }
        return max(0, limit - reading.usedBytes)
    }

    /// The shortfall that refuses the run, or `nil` when it fits or
    /// when no number governs.
    public static func shortfall(
        pendingBytes: Int64, reading: QuotaReading?, capBytes: Int64?
    ) -> Shortfall? {
        guard let free = freeBytes(reading: reading, capBytes: capBytes) else { return nil }
        guard pendingBytes > free else { return nil }
        return Shortfall(neededBytes: pendingBytes, freeBytes: free)
    }

    /// The reason the target row and the run record carry, per 13.5
    /// and 6.6.
    public static func blockedLine(_ shortfall: Shortfall) -> String {
        "this target needs \(shortfall.missingBytes) more bytes for the next snapshot"
    }

    /// The reason a target blocked by an upload error carries, when
    /// the prune of 5.14 freed too little.
    public static let prunedAndStillFullLine =
        "this target is full. Make space or raise the cap to continue."
}
