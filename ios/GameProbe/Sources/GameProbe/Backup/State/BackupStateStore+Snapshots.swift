import Foundation

/// What one device namespace holds on one target: the newest
/// manifest per stream and the snapshot ledger the restore picker
/// reads.
extension BackupStateStore {

    // MARK: - Manifests

    /// The next run diffs against this manifest and reuses the blobs
    /// it names. The sweep never deletes those, because the manifest
    /// is still on the target.
    public func recordUploadedManifest(
        _ manifest: SnapshotManifest,
        snapshotId: String,
        targetId: String,
        uploadedAt: Date
    ) throws {
        try database.run(
            """
            INSERT INTO uploaded_manifest
                (targetId, gameKey, snapshotId, manifest, uploadedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                snapshotId = excluded.snapshotId,
                manifest = excluded.manifest,
                uploadedAt = excluded.uploadedAt
            """,
            [
                .text(targetId), .text(manifest.gameKey), .text(snapshotId),
                .blob(try manifest.jsonData()), .real(uploadedAt.timeIntervalSince1970),
            ])
    }

    public func lastUploadedManifest(
        targetId: String, gameKey: String
    ) throws -> UploadedManifestRecord? {
        let rows = try database.query(
            """
            SELECT snapshotId, manifest, uploadedAt FROM uploaded_manifest
            WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        // The target holds the same manifest, so a row this build cannot
        // decode counts as no earlier snapshot of this game only.
        guard let row = rows.first,
            let snapshotId = row[0].string,
            let payload = row[1].data,
            let uploadedAt = row[2].double,
            let manifest = try? SnapshotManifest.decode(json: payload)
        else { return nil }
        return UploadedManifestRecord(
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            manifest: manifest,
            uploadedAt: Date(timeIntervalSince1970: uploadedAt))
    }

    /// Drops the diff base for one stream, so the next run writes
    /// a full snapshot. The delete of 5.13 calls it.
    public func clearUploadedManifest(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM uploaded_manifest WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - The snapshot ledger

    /// The snapshot ids one stream holds on one target, per SPEC
    /// 5.10.
    ///
    /// The prune of 5.10 reads this instead of listing, because
    /// `list` has five callers and the prune is not one of them, per
    /// 8.1. A rebuilt cache knows fewer ids and therefore prunes
    /// less, which loses nothing: the sweep of 5.11 still reclaims
    /// the blobs, and a manifest nobody deletes still restores.
    ///
    /// The manifest does not carry the one-off mark, so a rebuild records a snapshot again without it,
    /// and a saved mark stays.
    public func recordSnapshot(_ entry: SnapshotLedgerEntry) throws {
        try database.run(
            """
            INSERT INTO snapshot_ledger
                (targetId, gameKey, snapshotId, createdAt, oneOff)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey, snapshotId) DO UPDATE SET
                createdAt = excluded.createdAt,
                oneOff = MAX(oneOff, excluded.oneOff)
            """,
            [
                .text(entry.targetId), .text(entry.gameKey), .text(entry.snapshotId),
                .real(entry.createdAt.timeIntervalSince1970),
                .integer(entry.isOneOff ? 1 : 0),
            ])
    }

    /// Every snapshot the ledger holds for one stream, oldest first.
    public func snapshots(targetId: String, gameKey: String) throws -> [SnapshotLedgerEntry] {
        let rows = try database.query(
            """
            SELECT snapshotId, createdAt, oneOff FROM snapshot_ledger
            WHERE targetId = ? AND gameKey = ? ORDER BY snapshotId
            """,
            [.text(targetId), .text(gameKey)])
        return rows.compactMap { row in
            guard let snapshotId = row[0].string,
                let createdAt = row[1].double,
                let oneOff = row[2].int64
            else { return nil }
            return SnapshotLedgerEntry(
                targetId: targetId,
                gameKey: gameKey,
                snapshotId: snapshotId,
                createdAt: Date(timeIntervalSince1970: createdAt),
                isOneOff: oneOff != 0)
        }
    }

    public func removeSnapshots(
        targetId: String, gameKey: String, snapshotIds: [String]
    ) throws {
        try database.transaction {
            for id in snapshotIds {
                try database.run(
                    """
                    DELETE FROM snapshot_ledger
                    WHERE targetId = ? AND gameKey = ? AND snapshotId = ?
                    """,
                    [.text(targetId), .text(gameKey), .text(id)])
            }
        }
    }
}
