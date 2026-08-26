import Foundation

/// The app-wide retention setting, per SPEC 5.10. There are no
/// per-game controls.
public enum RetentionPreset: String, Codable, Sendable, CaseIterable, Equatable {
    case small
    case standard
    case deep
}

/// Which kind of stream a set of snapshots belongs to, per SPEC 5.3
/// and 5.10.
public enum StreamKind: Sendable, CaseIterable, Equatable {
    /// A game that is still installed.
    case game
    /// A game with no local container. It keeps its newest few, so a
    /// game deleted long ago stays restorable at a small cost.
    case gameWithoutContainer
    /// The stream that belongs to no game.
    case preferences
}

/// One snapshot of one stream, by id and by date.
public struct DatedSnapshot: Equatable, Sendable {
    public let id: String
    public let date: Date

    public init(id: String, date: Date) {
        self.id = id
        self.date = date
    }

    /// The date from the id itself, per 5.2. `nil` when the id does
    /// not carry the form of 5.2.
    public init?(id: String) {
        guard let date = BackupKeys.timestamp(ofSnapshotId: id) else { return nil }
        self.init(id: id, date: date)
    }
}

/// How many snapshots one rung of the ladder holds.
public struct RetentionLadder: Equatable, Sendable {
    /// The newest snapshots, whatever their dates.
    public let last: Int
    /// The newest snapshot of each of the last days that have one.
    public let daily: Int
    /// The newest snapshot of each of the last weeks that have one.
    public let weekly: Int

    public init(last: Int, daily: Int = 0, weekly: Int = 0) {
        self.last = last
        self.daily = daily
        self.weekly = weekly
    }
}

/// What the prune keeps and what it deletes.
///
/// Both lists are sorted by id, which is chronological order, per
/// 5.2.
public struct RetentionPlan: Equatable, Sendable {
    public let keep: [String]
    public let drop: [String]

    public init(keep: [String], drop: [String]) {
        self.keep = keep
        self.drop = drop
    }
}

/// The retention ladder of SPEC 5.10, as a pure function.
///
/// The prune deletes manifests only. It never names a blob, per
/// invariant 1.1.6. Blobs leave through the sweep of 5.11.
///
/// A rung counts the last days or weeks that hold a snapshot, not the
/// calendar days behind the clock. Section 5.10 states the ladder in
/// the words restic states it in, and this is what those words mean
/// there. A stream that went quiet for a month therefore still keeps
/// its 7 daily rungs. The function needs no clock, which is what
/// makes it repeatable.
public enum RetentionPolicy {

    /// The ladder for one stream and one preset.
    ///
    /// Section 5.10 states the standard game ladder, the flat 10 of
    /// the preferences stream, and the flat 3 of a game with no
    /// container. It names no numbers for small and for deep, so
    /// small halves the standard game ladder and deep doubles it. The
    /// two flat rules do not scale, because 5.10 states them without
    /// a preset. A preferences snapshot is a few KB, and a game with
    /// no container is history nobody adds to.
    public static func ladder(
        kind: StreamKind, preset: RetentionPreset
    ) -> RetentionLadder {
        switch kind {
        case .preferences:
            return RetentionLadder(last: 10)
        case .gameWithoutContainer:
            return RetentionLadder(last: 3)
        case .game:
            switch preset {
            case .small:
                return RetentionLadder(last: 5, daily: 3, weekly: 2)
            case .standard:
                return RetentionLadder(last: 10, daily: 7, weekly: 4)
            case .deep:
                return RetentionLadder(last: 20, daily: 14, weekly: 8)
            }
        }
    }

    public static func plan(
        for snapshots: [DatedSnapshot],
        kind: StreamKind,
        preset: RetentionPreset
    ) -> RetentionPlan {
        plan(for: snapshots, ladder: ladder(kind: kind, preset: preset))
    }

    public static func plan(
        for snapshots: [DatedSnapshot], ladder: RetentionLadder
    ) -> RetentionPlan {
        // Newest first. Two snapshots of the same second break the
        // tie by id, so the answer never depends on the input order.
        let ordered = snapshots.sorted {
            $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date
        }

        var keep = Set<String>()
        for snapshot in ordered.prefix(max(0, ladder.last)) {
            keep.insert(snapshot.id)
        }
        keepNewestPerBucket(ordered, count: ladder.daily, keep: &keep, bucket: dayBucket)
        keepNewestPerBucket(ordered, count: ladder.weekly, keep: &keep, bucket: weekBucket)

        let ids = snapshots.map(\.id).sorted()
        return RetentionPlan(
            keep: ids.filter { keep.contains($0) },
            drop: ids.filter { !keep.contains($0) })
    }

    // MARK: - Buckets

    private static func keepNewestPerBucket(
        _ ordered: [DatedSnapshot],
        count: Int,
        keep: inout Set<String>,
        bucket: (Date) -> Int
    ) {
        guard count > 0 else { return }
        var seen = Set<Int>()
        for snapshot in ordered {
            let index = bucket(snapshot.date)
            if seen.contains(index) { continue }
            if seen.count == count { break }
            seen.insert(index)
            keep.insert(snapshot.id)
        }
    }

    private static let secondsPerDay = 86_400.0

    /// The UTC day the date falls in, counted from 1970-01-01.
    static func dayBucket(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / secondsPerDay))
    }

    /// The UTC week the date falls in. 1970-01-01 was a Thursday, so
    /// the shift of 3 puts the boundary on Monday.
    static func weekBucket(_ date: Date) -> Int {
        Int(floor(Double(dayBucket(date) + 3) / 7.0))
    }
}
