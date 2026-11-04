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
        /// limit and the room left under the cap.
        public var freeBytes: Int64

        public init(neededBytes: Int64, freeBytes: Int64) {
            self.neededBytes = neededBytes
            self.freeBytes = freeBytes
        }

        public var missingBytes: Int64 {
            max(0, neededBytes - freeBytes)
        }
    }

    /// What the target has left, or `nil` where no number governs.
    ///
    /// The provider limit counts the whole account, because that is
    /// what fills it. The cap of 5.14 limits what Empo stores, so it
    /// counts `storedBytes`, Empo's own bytes on the target. The cap
    /// holds on a target that answers no space query too.
    public static func freeBytes(
        reading: QuotaReading?, capBytes: Int64?, storedBytes: Int64
    ) -> Int64? {
        let underTheLimit = reading?.freeBytes
        let underTheCap = capBytes.map { max(0, $0 - storedBytes) }
        switch (underTheLimit, underTheCap) {
        case (let limit?, let cap?): return min(limit, cap)
        case (let limit?, nil): return limit
        case (nil, let cap?): return cap
        case (nil, nil): return nil
        }
    }

    /// The shortfall that refuses the run, or `nil` when it fits or
    /// when no number governs.
    public static func shortfall(
        pendingBytes: Int64, reading: QuotaReading?, capBytes: Int64?, storedBytes: Int64
    ) -> Shortfall? {
        guard
            let free = freeBytes(reading: reading, capBytes: capBytes, storedBytes: storedBytes)
        else { return nil }
        guard pendingBytes > free else { return nil }
        return Shortfall(neededBytes: pendingBytes, freeBytes: free)
    }

    /// The reason the target row and the run record carry, per 13.5
    /// and 6.6.
    public static func blockedLine(_ shortfall: Shortfall) -> String {
        let missing = ByteCountFormatter.string(
            fromByteCount: shortfall.missingBytes, countStyle: .file)
        return "This location needs \(missing) more space for the next backup."
    }

    /// The reason a target blocked by an upload error carries, when
    /// the prune of 5.14 freed too little.
    public static let prunedAndStillFullLine =
        "This location is full. Free up space on it, or raise its storage limit."
}
