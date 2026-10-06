import Foundation

/// The prune of SPEC 5.10, over the snapshot ledger of one stream.
///
/// `RetentionPolicy` holds the ladder. This adds the one rule the
/// ladder does not cover: the one-off full snapshot of 5.15 keeps
/// its own retention rule of one, so it sits outside the ladder and
/// only the newest one survives.
///
/// The prune deletes manifests only. It never names a blob, per
/// invariant 1.1.6. Blobs leave through the sweep of 5.11.
public enum PrunePlan {

    /// Which snapshots one stream keeps and which it drops.
    ///
    /// Ticket 014 clears the one-off mark once the replaced tree is
    /// gone, and the ordinary ladder governs that snapshot from then
    /// on.
    public static func plan(
        ledger: [SnapshotLedgerEntry], kind: StreamKind, preset: RetentionPreset
    ) -> RetentionPlan {
        let ordinary = ledger.filter { !$0.isOneOff }
        let oneOff = ledger.filter(\.isOneOff).sorted { $0.snapshotId < $1.snapshotId }

        let ladder = RetentionPolicy.plan(
            for: ordinary.map { DatedSnapshot(id: $0.snapshotId, date: $0.createdAt) },
            kind: kind,
            preset: preset)

        var keep = Set(ladder.keep)
        if let newest = oneOff.last { keep.insert(newest.snapshotId) }

        let ids = ledger.map(\.snapshotId).sorted()
        return RetentionPlan(
            keep: ids.filter { keep.contains($0) },
            drop: ids.filter { !keep.contains($0) })
    }

    /// The stream kind of 5.10 for one game.
    public static func kind(hasLocalContainer: Bool) -> StreamKind {
        hasLocalContainer ? .game : .gameWithoutContainer
    }
}
