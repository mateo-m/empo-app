import Foundation

/// The space check of SPEC 11.8, which is the restore twin of the
/// rule in 6.4.
///
/// Before a restore starts, Empo sums the bytes it will write against
/// free disk space and refuses with the shortfall named.
///
/// **It never deletes local data to fit**, displaced copies and
/// replaced trees included. That is invariant 1's restore twin, and
/// nothing in this file or downstream of it deletes a local file to
/// make room.
public enum RestoreSpaceCheck {

    /// What a refused restore reports.
    public struct Shortfall: Equatable, Sendable {

        /// What the restore would write and stage.
        public var neededBytes: Int64
        /// What the volume has now.
        public var freeBytes: Int64

        public init(neededBytes: Int64, freeBytes: Int64) {
            self.neededBytes = neededBytes
            self.freeBytes = freeBytes
        }

        public var missingBytes: Int64 {
            max(0, neededBytes - freeBytes)
        }
    }

    /// The shortfall that refuses the restore, or `nil` when it fits.
    public static func shortfall(neededBytes: Int64, freeSpaceBytes: Int64) -> Shortfall? {
        guard neededBytes > freeSpaceBytes else { return nil }
        return Shortfall(neededBytes: neededBytes, freeBytes: freeSpaceBytes)
    }

    /// The shortfall for a whole plan.
    public static func shortfall(plan: RestorePlan, freeSpaceBytes: Int64) -> Shortfall? {
        shortfall(neededBytes: plan.bytesNeeded, freeSpaceBytes: freeSpaceBytes)
    }

    /// The line that refuses the restore, per 11.8.
    ///
    /// `missingSize` is the byte count already formatted, such as
    /// "2.1 GB", and `deviceName` is what the device calls itself,
    /// such as "iPhone". The model layer holds no formatter, the way
    /// `QuotaCheck` holds none.
    public static func refusalLine(missingSize: String, deviceName: String) -> String {
        "This restore needs \(missingSize) more space on this \(deviceName)."
    }

    /// The line for a restore that ran out of room after it started.
    ///
    /// Everything already written stays, and the originals stay safe
    /// as displaced copies.
    public static func ranOutLine(missingSize: String) -> String {
        "This restore stopped because the device ran out of space. It needed \(missingSize) more. "
            + "The files already put back are still here, and your earlier files are still here "
            + "as copies."
    }
}
