import Foundation

/// The size and the modified time a scan read for one path. Rule 2 of
/// SPEC 6.4 compares these two values before and after the copy.
public struct FileStamp: Equatable, Sendable {
    public let size: Int64
    public let modifiedAt: Date

    public init(size: Int64, modifiedAt: Date) {
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Which path a game's save members take, per SPEC 6.4.
public enum StagingRoute: Equatable, Sendable {
    /// Copy the save members into `staging/`, then hash and upload
    /// the copies.
    case staged
    /// Hash, upload, and re-hash from the game tree, and mark the
    /// path partial when the second hash differs. This path needs no
    /// staging space.
    case inPlace(InPlaceReason)
    /// Not even the in-place path fits. The run stops for this game,
    /// per rule 6.
    case notEnoughSpace

    public enum InPlaceReason: String, Equatable, Sendable {
        /// The save members are over the 512 MB cap, per rule 3.
        case overStagingCap
        /// The free space is under the members' size plus the 200 MB
        /// floor, per rule 4.
        case belowFreeSpaceFloor
    }
}

/// What to do with a file that changed while it was being staged, per
/// rule 2 of SPEC 6.4.
public enum StageRecheck: Equatable, Sendable {
    /// Size and modified time still match the scan. Keep the copy.
    case accepted
    /// The file changed once. Copy it again.
    case restage
    /// The file changed twice. Skip it and mark the path partial, per
    /// 5.9. The path retries on the next run.
    case skipAndMarkPartial
}

/// The disk budget of SPEC 6.4, as pure rules.
///
/// Four of the seven rules are decisions, and they are here. `route`
/// answers rules 3, 4, and 6, and `recheck` answers rule 2.
///
/// The other three bind the snapshot engine of ticket 006, which does
/// the work these rules judge:
///
/// 1. Stage save members only, never the whole tree. No game runs
///    during staging, so graphics, audio, and the executable hash and
///    upload in place from the game tree.
/// 5. Compress one blob at a time, streaming into the outbox file, so
///    the peak cost is one file and not the whole set.
/// 7. Empo never deletes local data to make room. This is invariant
///    1. Nothing in this file or in the state store deletes a game
///    file, and nothing downstream may either.
///
/// Free space is a parameter. A `volumeAvailableCapacity` read inside
/// these functions would make the tests depend on the host.
public enum StagingBudget {

    /// The cap on the staging area, per rule 3.
    public static let stagingCapBytes: Int64 = 512 * 1024 * 1024
    /// The free-space floor a staged run must leave, per rule 4.
    public static let freeSpaceFloorBytes: Int64 = 200 * 1024 * 1024

    /// Which path the game's save members take.
    ///
    /// - `saveMembersBytes`: every save member of this game together.
    /// - `largestMemberBytes`: the biggest single member. The in-place
    ///   path compresses one blob at a time into the outbox, per rule
    ///   5, so one member is the peak cost of that path. A compressed
    ///   blob is at most its input, so this is an upper bound.
    /// - `freeSpaceBytes`: what the volume has now.
    public static func route(
        saveMembersBytes: Int64,
        largestMemberBytes: Int64,
        freeSpaceBytes: Int64
    ) -> StagingRoute {
        let inPlaceFits = freeSpaceBytes >= largestMemberBytes
        if saveMembersBytes > stagingCapBytes {
            return inPlaceFits ? .inPlace(.overStagingCap) : .notEnoughSpace
        }
        if freeSpaceBytes < saveMembersBytes + freeSpaceFloorBytes {
            return inPlaceFits ? .inPlace(.belowFreeSpaceFloor) : .notEnoughSpace
        }
        return .staged
    }

    /// The line the Backups screen shows when a game stops for space,
    /// per rule 6.
    public static let notEnoughSpaceLine = "not enough space on this device"

    /// What to do after a copy, given how many copies this path has
    /// already had.
    ///
    /// `attempt` counts from 1 for the first copy.
    public static func recheck(
        scanned: FileStamp, afterCopy: FileStamp, attempt: Int
    ) -> StageRecheck {
        if scanned == afterCopy { return .accepted }
        return attempt >= 2 ? .skipAndMarkPartial : .restage
    }
}
