import Foundation

/// What one device namespace holds on one target: the newest
/// manifest per stream, the blobs a manifest proved present, and
/// the snapshot ledger the restore picker reads.
extension BackupStateStore {

    // MARK: - Manifests and known blobs

    /// Writes the manifest row and marks every hash it names known
    /// present, in one transaction.
    ///
    /// This is the only writer of `known_blob`, on purpose. A blob
    /// counts as known present only once a manifest that names it
    /// uploaded successfully, per 6.2. That is the moment its
    /// existence is proven.
    public func recordUploadedManifest(
        _ manifest: SnapshotManifest,
        snapshotId: String,
        targetId: String,
        namespaceId: String,
        uploadedAt: Date
    ) throws {
        let payload = try manifest.jsonData()
        try database.transaction {
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
                    .blob(payload), .real(uploadedAt.timeIntervalSince1970),
                ])

            // The algorithm rides with the hash. A later run that
            // reuses the blob has to name what the blob holds, and
            // the hash alone cannot give that back.
            var algorithms: [String: BlobCompression] = [:]
            for entry in manifest.entries {
                algorithms[entry.hash] = entry.compression
                for chunk in entry.chunks ?? [] where algorithms[chunk] == nil {
                    algorithms[chunk] = .stored
                }
            }
            for hash in algorithms.keys.sorted() {
                try database.run(
                    """
                    INSERT OR IGNORE INTO known_blob
                        (targetId, namespaceId, hash, compression, provenAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(targetId), .text(namespaceId), .text(hash),
                        .text((algorithms[hash] ?? .stored).rawValue),
                        .real(uploadedAt.timeIntervalSince1970),
                    ])
            }
        }
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
        guard let row = rows.first,
            let snapshotId = row[0].string,
            let payload = row[1].data,
            let uploadedAt = row[2].double
        else { return nil }
        return UploadedManifestRecord(
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            manifest: try SnapshotManifest.decode(json: payload),
            uploadedAt: Date(timeIntervalSince1970: uploadedAt))
    }

    /// Drops the diff base for one stream, so the next run writes
    /// a full snapshot. The delete of 5.13 calls it.
    public func clearUploadedManifest(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM uploaded_manifest WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    public func isBlobKnownPresent(
        hash: String, targetId: String, namespaceId: String
    ) throws -> Bool {
        let rows = try database.query(
            """
            SELECT 1 FROM known_blob
            WHERE targetId = ? AND namespaceId = ? AND hash = ?
            """,
            [.text(targetId), .text(namespaceId), .text(hash)])
        return !rows.isEmpty
    }

    /// The algorithm a known blob went up with, or `nil` where this
    /// namespace has no proof the blob is there.
    public func knownBlobCompression(
        hash: String, targetId: String, namespaceId: String
    ) throws -> BlobCompression? {
        let rows = try database.query(
            """
            SELECT compression FROM known_blob
            WHERE targetId = ? AND namespaceId = ? AND hash = ?
            """,
            [.text(targetId), .text(namespaceId), .text(hash)])
        guard let text = rows.first?.first?.string else { return nil }
        return BlobCompression(rawValue: text)
    }

    public func knownBlobHashes(
        targetId: String, namespaceId: String
    ) throws -> Set<String> {
        let rows = try database.query(
            "SELECT hash FROM known_blob WHERE targetId = ? AND namespaceId = ?",
            [.text(targetId), .text(namespaceId)])
        return Set(rows.compactMap { $0.first?.string })
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
    public func recordSnapshot(_ entry: SnapshotLedgerEntry) throws {
        try database.run(
            """
            INSERT INTO snapshot_ledger
                (targetId, gameKey, snapshotId, createdAt, oneOff)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey, snapshotId) DO UPDATE SET
                createdAt = excluded.createdAt,
                oneOff = excluded.oneOff
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
