import Foundation

/// What the open did, per SPEC 6.3.
public enum BackupStateOpen: Equatable, Sendable {
    /// No database was there. A fresh install, or a deleted root.
    case created
    /// The file was there and its schema matched.
    case opened
    /// The file was there and could not serve, so this store is a new
    /// empty one.
    case rebuilt(BackupStateRebuild)
}

/// Why the store threw away what it found, per SPEC 6.3.
public enum BackupStateRebuild: Equatable, Sendable {
    /// The schema version on disk was not this build's version. An
    /// older one and a newer one both land here, because the cache is
    /// never truth and a rebuild costs CPU and not bytes.
    case schemaVersion(found: Int32)
    /// SQLite could not read the file.
    case corrupt
}

/// The local cache of SPEC 6.2: one database for every target, with a
/// `targetId` column.
///
/// The store is a cache and never truth, per 6.3. When the open
/// reports anything but `.opened`, the caller downloads the newest
/// manifest from the target and rebuilds from it. When the target is
/// unreachable as well, the caller re-hashes and uploads, and the
/// content-addressed blob store discards the duplicates. A lost cache
/// costs CPU and not bytes.
///
/// The rebuild reads manifests and never a remote listing, per 6.3,
/// and no listing runs inside a run. The sweep of 5.11 is the only
/// operation that lists on the backup path.
///
/// Per-game intent is not derived data, so it never lives here. It
/// lives in `EmpoState/backup.json`, per 3.8. `GameBackupIntent` owns
/// that file.
///
/// The class is not `Sendable`. One store belongs to the task that
/// opened it.
public final class BackupStateStore {

    /// The schema this build writes. Raise it when a table changes.
    public static let schemaVersion: Int32 = 5

    /// What the open did. `needsRebuildFromTarget` reads it.
    public let openOutcome: BackupStateOpen

    private let database: SQLiteDatabase

    /// Opens the store at `url`, or an in-memory store when `url` is
    /// `nil`.
    ///
    /// A file this build cannot serve never blocks a run. The open
    /// deletes it and makes an empty store instead, and the outcome
    /// says so.
    public init(url: URL?) throws {
        if let url {
            do {
                let (database, outcome) = try Self.openFile(at: url)
                self.database = database
                self.openOutcome = outcome
            } catch {
                Self.removeDatabaseFiles(at: url)
                let database = try SQLiteDatabase(url: url)
                try Self.createSchema(in: database)
                self.database = database
                self.openOutcome = .rebuilt(.corrupt)
            }
        } else {
            let database = try SQLiteDatabase(url: nil)
            try Self.createSchema(in: database)
            self.database = database
            self.openOutcome = .created
        }
    }

    /// The caller must rebuild from the newest manifest on the
    /// target, per 6.3.
    public var needsRebuildFromTarget: Bool {
        openOutcome != .opened
    }

    public func close() {
        database.close()
    }

    // MARK: - Open and migrate

    private static func openFile(at url: URL) throws -> (SQLiteDatabase, BackupStateOpen) {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let database = try SQLiteDatabase(url: url)
        let version = try database.userVersion
        let tables = try database.tableNames()

        if !existed || tables.isEmpty {
            try createSchema(in: database)
            return (database, .created)
        }
        if version == schemaVersion {
            return (database, .opened)
        }
        // No migration path. The cache is never truth, per 6.3, so
        // dropping it is cheaper to write and cheaper to trust than a
        // migration for every version pair.
        for table in tables where !table.hasPrefix("sqlite_") {
            try database.execute("DROP TABLE IF EXISTS \"\(table)\"")
        }
        try createSchema(in: database)
        return (database, .rebuilt(.schemaVersion(found: version)))
    }

    /// The write-ahead log leaves two files beside the database. A
    /// delete that misses them leaves SQLite reading the old log.
    private static func removeDatabaseFiles(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            try? manager.removeItem(atPath: path)
        }
    }

    private static func createSchema(in database: SQLiteDatabase) throws {
        try database.execute(schema)
        try database.setUserVersion(schemaVersion)
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS uploaded_manifest (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            snapshotId TEXT NOT NULL,
            manifest BLOB NOT NULL,
            uploadedAt REAL NOT NULL,
            PRIMARY KEY (targetId, gameKey)
        );
        CREATE TABLE IF NOT EXISTS known_blob (
            targetId TEXT NOT NULL,
            namespaceId TEXT NOT NULL,
            hash TEXT NOT NULL,
            compression TEXT NOT NULL,
            provenAt REAL NOT NULL,
            PRIMARY KEY (targetId, namespaceId, hash)
        );
        CREATE TABLE IF NOT EXISTS run_checkpoint (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            snapshotId TEXT NOT NULL,
            uploadedBytes INTEGER NOT NULL,
            pendingPaths TEXT NOT NULL,
            confirmedBlobs TEXT NOT NULL,
            updatedAt REAL NOT NULL,
            PRIMARY KEY (targetId, gameKey)
        );
        CREATE TABLE IF NOT EXISTS snapshot_ledger (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            snapshotId TEXT NOT NULL,
            createdAt REAL NOT NULL,
            oneOff INTEGER NOT NULL,
            PRIMARY KEY (targetId, gameKey, snapshotId)
        );
        CREATE TABLE IF NOT EXISTS target_status (
            targetId TEXT NOT NULL PRIMARY KEY,
            failureKind TEXT,
            failureDetail TEXT,
            failedAt REAL,
            quotaUsed INTEGER,
            quotaLimit INTEGER,
            quotaAt REAL
        );
        CREATE TABLE IF NOT EXISTS target_maintenance (
            targetId TEXT NOT NULL PRIMARY KEY,
            lastSweepAt REAL
        );
        CREATE TABLE IF NOT EXISTS dirty_game (
            gameKey TEXT NOT NULL PRIMARY KEY,
            markedAt REAL NOT NULL,
            reason TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pending_deletion (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            requestedAt REAL NOT NULL,
            rescuedBuckets TEXT NOT NULL,
            PRIMARY KEY (targetId, gameKey)
        );
        CREATE TABLE IF NOT EXISTS staleness (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            lastSuccessAt REAL,
            lastAttemptAt REAL,
            partialSince REAL,
            PRIMARY KEY (targetId, gameKey)
        );
        CREATE TABLE IF NOT EXISTS run_record (
            id TEXT NOT NULL PRIMARY KEY,
            targetId TEXT NOT NULL,
            startedAt REAL NOT NULL,
            finishedAt REAL,
            outcome TEXT NOT NULL,
            uploadedBytes INTEGER NOT NULL,
            gameCount INTEGER NOT NULL,
            detail TEXT
        );
        CREATE TABLE IF NOT EXISTS intent_record (
            kind TEXT NOT NULL PRIMARY KEY,
            targetId TEXT NOT NULL,
            gameKey TEXT,
            snapshotId TEXT,
            uploadedBytes INTEGER NOT NULL,
            remainingBytes INTEGER NOT NULL,
            restoreScope TEXT,
            replacesTree INTEGER NOT NULL,
            createdAt REAL NOT NULL,
            asked INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scheduler_state (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS partial_tally (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            path TEXT NOT NULL,
            runs INTEGER NOT NULL,
            PRIMARY KEY (targetId, gameKey, path)
        );
        CREATE INDEX IF NOT EXISTS run_record_startedAt ON run_record (startedAt);
        """

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

    // MARK: - Checkpoints

    public func saveCheckpoint(_ checkpoint: RunCheckpoint) throws {
        try database.run(
            """
            INSERT INTO run_checkpoint
                (targetId, gameKey, snapshotId, uploadedBytes, pendingPaths,
                 confirmedBlobs, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                pendingPaths = excluded.pendingPaths,
                confirmedBlobs = excluded.confirmedBlobs,
                updatedAt = excluded.updatedAt
            """,
            [
                .text(checkpoint.targetId), .text(checkpoint.gameKey),
                .text(checkpoint.snapshotId), .integer(checkpoint.uploadedBytes),
                .text(Self.encodeList(checkpoint.pendingPaths)),
                .text(Self.encodeList(checkpoint.confirmedBlobs.map(\.text))),
                .real(checkpoint.updatedAt.timeIntervalSince1970),
            ])
    }

    public func checkpoint(targetId: String, gameKey: String) throws -> RunCheckpoint? {
        let rows = try database.query(
            """
            SELECT snapshotId, uploadedBytes, pendingPaths, confirmedBlobs, updatedAt
            FROM run_checkpoint WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        guard let row = rows.first,
            let snapshotId = row[0].string,
            let uploadedBytes = row[1].int64,
            let paths = row[2].string,
            let blobs = row[3].string,
            let updatedAt = row[4].double
        else { return nil }
        return RunCheckpoint(
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            uploadedBytes: uploadedBytes,
            pendingPaths: Self.decodeList(paths),
            confirmedBlobs: Self.decodeList(blobs).compactMap(ConfirmedBlob.init(text:)),
            updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    public func clearCheckpoint(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM run_checkpoint WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - Dirty flags

    public func markDirty(gameKey: String, reason: String, at date: Date) throws {
        try database.run(
            """
            INSERT INTO dirty_game (gameKey, markedAt, reason) VALUES (?, ?, ?)
            ON CONFLICT (gameKey) DO UPDATE SET
                markedAt = excluded.markedAt, reason = excluded.reason
            """,
            [.text(gameKey), .real(date.timeIntervalSince1970), .text(reason)])
    }

    public func dirtyGames() throws -> [DirtyMark] {
        let rows = try database.query(
            "SELECT gameKey, markedAt, reason FROM dirty_game ORDER BY markedAt, gameKey")
        return rows.compactMap { row in
            guard let gameKey = row[0].string,
                let markedAt = row[1].double,
                let reason = row[2].string
            else { return nil }
            return DirtyMark(
                gameKey: gameKey,
                markedAt: Date(timeIntervalSince1970: markedAt),
                reason: reason)
        }
    }

    public func clearDirty(gameKey: String) throws {
        try database.run("DELETE FROM dirty_game WHERE gameKey = ?", [.text(gameKey)])
    }

    // MARK: - Pending deletions

    public func addPendingDeletion(_ deletion: PendingDeletion) throws {
        try database.run(
            """
            INSERT INTO pending_deletion
                (targetId, gameKey, requestedAt, rescuedBuckets)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                requestedAt = excluded.requestedAt,
                rescuedBuckets = excluded.rescuedBuckets
            """,
            [
                .text(deletion.targetId), .text(deletion.gameKey),
                .real(deletion.requestedAt.timeIntervalSince1970),
                .text(Self.encodeList(deletion.rescuedBuckets)),
            ])
    }

    public func pendingDeletions(targetId: String) throws -> [PendingDeletion] {
        let rows = try database.query(
            """
            SELECT gameKey, requestedAt, rescuedBuckets FROM pending_deletion
            WHERE targetId = ? ORDER BY requestedAt, gameKey
            """,
            [.text(targetId)])
        return rows.compactMap { row in
            guard let gameKey = row[0].string,
                let requestedAt = row[1].double,
                let buckets = row[2].string
            else { return nil }
            return PendingDeletion(
                targetId: targetId,
                gameKey: gameKey,
                requestedAt: Date(timeIntervalSince1970: requestedAt),
                rescuedBuckets: Self.decodeList(buckets))
        }
    }

    public func clearPendingDeletion(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM pending_deletion WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - Staleness clocks

    public func saveStaleness(_ clock: StalenessClock) throws {
        func value(_ date: Date?) -> SQLiteValue {
            date.map { .real($0.timeIntervalSince1970) } ?? .null
        }
        try database.run(
            """
            INSERT INTO staleness
                (targetId, gameKey, lastSuccessAt, lastAttemptAt, partialSince)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                lastSuccessAt = excluded.lastSuccessAt,
                lastAttemptAt = excluded.lastAttemptAt,
                partialSince = excluded.partialSince
            """,
            [
                .text(clock.targetId), .text(clock.gameKey),
                value(clock.lastSuccessAt), value(clock.lastAttemptAt),
                value(clock.partialSince),
            ])
    }

    public func staleness(targetId: String, gameKey: String) throws -> StalenessClock? {
        let rows = try database.query(
            """
            SELECT lastSuccessAt, lastAttemptAt, partialSince FROM staleness
            WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        guard let row = rows.first else { return nil }
        func date(_ value: SQLiteValue) -> Date? {
            value.double.map { Date(timeIntervalSince1970: $0) }
        }
        return StalenessClock(
            targetId: targetId,
            gameKey: gameKey,
            lastSuccessAt: date(row[0]),
            lastAttemptAt: date(row[1]),
            partialSince: date(row[2]))
    }

    // MARK: - The scheduler's own state, per SPEC 7.10 and 7.11

    /// The keys `scheduler_state` holds.
    private enum SchedulerKey: String {
        /// The consecutive runs lost to a force quit, per 7.10.
        case interruptedRunTally = "interrupted-run-tally"
        /// The notifications already posted, per 7.11. A key that
        /// leaves the list arms its cause again.
        case notificationLedger = "notification-ledger"
    }

    private func schedulerValue(_ key: SchedulerKey) throws -> String? {
        let rows = try database.query(
            "SELECT value FROM scheduler_state WHERE key = ?", [.text(key.rawValue)])
        return rows.first?[0].string
    }

    private func setSchedulerValue(_ value: String, for key: SchedulerKey) throws {
        try database.run(
            """
            INSERT INTO scheduler_state (key, value) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value
            """,
            [.text(key.rawValue), .text(value)])
    }

    public func interruptedRunTally() throws -> InterruptedRunTally {
        let text = try schedulerValue(.interruptedRunTally) ?? "0"
        return InterruptedRunTally(count: Int(text) ?? 0)
    }

    public func saveInterruptedRunTally(_ tally: InterruptedRunTally) throws {
        try setSchedulerValue(String(tally.count), for: .interruptedRunTally)
    }

    public func notificationLedger() throws -> BackupNotificationLedger {
        guard let text = try schedulerValue(.notificationLedger), !text.isEmpty else {
            return BackupNotificationLedger()
        }
        return BackupNotificationLedger(
            postedKeys: Set(text.split(separator: "\n").map(String.init)))
    }

    public func saveNotificationLedger(_ ledger: BackupNotificationLedger) throws {
        try setSchedulerValue(
            ledger.postedKeys.sorted().joined(separator: "\n"), for: .notificationLedger)
    }

    // MARK: - The partial-path clock of SPEC 7.2

    /// How many consecutive runs each save member came back partial
    /// on, for one game on one target.
    public func partialTally(targetId: String, gameKey: String) throws -> [String: Int] {
        let rows = try database.query(
            "SELECT path, runs FROM partial_tally WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
        var tally: [String: Int] = [:]
        for row in rows {
            guard let path = row[0].string, let runs = row[1].int64 else { continue }
            tally[path] = Int(runs)
        }
        return tally
    }

    /// Replaces the whole tally for one game on one target.
    ///
    /// It replaces rather than merges, because the count is
    /// consecutive: a path the run no longer reports partial must
    /// lose its count, per 7.2.
    public func savePartialTally(
        _ tally: [String: Int], targetId: String, gameKey: String
    ) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM partial_tally WHERE targetId = ? AND gameKey = ?",
                [.text(targetId), .text(gameKey)])
            for (path, runs) in tally.sorted(by: { $0.key < $1.key }) {
                try database.run(
                    """
                    INSERT INTO partial_tally (targetId, gameKey, path, runs)
                    VALUES (?, ?, ?, ?)
                    """,
                    [.text(targetId), .text(gameKey), .text(path), .integer(Int64(runs))])
            }
        }
    }

    // MARK: - Run history

    public func recordRun(_ run: BackupRunRecord) throws {
        try database.run(
            """
            INSERT INTO run_record
                (id, targetId, startedAt, finishedAt, outcome, uploadedBytes,
                 gameCount, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                finishedAt = excluded.finishedAt,
                outcome = excluded.outcome,
                uploadedBytes = excluded.uploadedBytes,
                gameCount = excluded.gameCount,
                detail = excluded.detail
            """,
            [
                .text(run.id), .text(run.targetId),
                .real(run.startedAt.timeIntervalSince1970),
                run.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(run.outcome.rawValue), .integer(run.uploadedBytes),
                .integer(Int64(run.gameCount)),
                run.detail.map { .text($0) } ?? .null,
            ])
    }

    /// The whole history, newest first. One global list, per 6.6.
    public func runHistory() throws -> [BackupRunRecord] {
        let rows = try database.query(
            """
            SELECT id, targetId, startedAt, finishedAt, outcome, uploadedBytes,
                   gameCount, detail
            FROM run_record ORDER BY startedAt DESC, id DESC
            """)
        return rows.compactMap { row in
            guard let id = row[0].string,
                let targetId = row[1].string,
                let startedAt = row[2].double,
                let outcome = row[4].string.flatMap(BackupRunOutcome.init(rawValue:)),
                let uploadedBytes = row[5].int64,
                let gameCount = row[6].int64
            else { return nil }
            return BackupRunRecord(
                id: id,
                targetId: targetId,
                startedAt: Date(timeIntervalSince1970: startedAt),
                finishedAt: row[3].double.map { Date(timeIntervalSince1970: $0) },
                outcome: outcome,
                uploadedBytes: uploadedBytes,
                gameCount: Int(gameCount),
                detail: row[7].string)
        }
    }

    /// Drops the rows past the 90-day retention of 6.6. The clock is
    /// a parameter, so the rule is testable.
    @discardableResult
    public func pruneRunHistory(now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-BackupRunRecord.retention)
        try database.run(
            "DELETE FROM run_record WHERE startedAt < ?",
            [.real(cutoff.timeIntervalSince1970)])
        return try changeCount()
    }

    // MARK: - Intent records

    public func saveIntent(_ intent: BackupIntentRecord) throws {
        try database.run(
            """
            INSERT INTO intent_record
                (kind, targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                 restoreScope, replacesTree, createdAt, asked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind) DO UPDATE SET
                targetId = excluded.targetId,
                gameKey = excluded.gameKey,
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                remainingBytes = excluded.remainingBytes,
                restoreScope = excluded.restoreScope,
                replacesTree = excluded.replacesTree,
                createdAt = excluded.createdAt,
                asked = excluded.asked
            """,
            [
                .text(intent.kind.rawValue), .text(intent.targetId),
                intent.gameKey.map { .text($0) } ?? .null,
                intent.snapshotId.map { .text($0) } ?? .null,
                .integer(intent.uploadedBytes),
                .integer(intent.remainingBytes),
                intent.restoreScope.map { .text($0.rawValue) } ?? .null,
                .integer(intent.replacesTheTree ? 1 : 0),
                .real(intent.createdAt.timeIntervalSince1970),
                .integer(intent.asked ? 1 : 0),
            ])
    }

    public func intent(kind: BackupIntentKind) throws -> BackupIntentRecord? {
        let rows = try database.query(
            """
            SELECT targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                   restoreScope, replacesTree, createdAt, asked
            FROM intent_record WHERE kind = ?
            """,
            [.text(kind.rawValue)])
        guard let row = rows.first,
            let targetId = row[0].string,
            let uploadedBytes = row[3].int64,
            let remainingBytes = row[4].int64,
            let replacesTree = row[6].int64,
            let createdAt = row[7].double,
            let asked = row[8].int64
        else { return nil }
        return BackupIntentRecord(
            kind: kind,
            targetId: targetId,
            gameKey: row[1].string,
            snapshotId: row[2].string,
            uploadedBytes: uploadedBytes,
            remainingBytes: remainingBytes,
            restoreScope: row[5].string.flatMap(RestoreScope.init(rawValue:)),
            replacesTheTree: replacesTree != 0,
            createdAt: Date(timeIntervalSince1970: createdAt),
            asked: asked != 0)
    }

    /// Records that the user saw the question. The same interruption
    /// never asks twice, per 6.5.
    public func markIntentAsked(kind: BackupIntentKind) throws {
        try database.run(
            "UPDATE intent_record SET asked = 1 WHERE kind = ?", [.text(kind.rawValue)])
    }

    public func clearIntent(kind: BackupIntentKind) throws {
        try database.run(
            "DELETE FROM intent_record WHERE kind = ?", [.text(kind.rawValue)])
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

    /// Drops every row that describes what one namespace holds.
    ///
    /// The split of 5.12 calls it. No namespace may reference
    /// another's blobs, so the new namespace starts from a full
    /// upload, and every row that would suppress an upload has to
    /// go. The run history and the staleness clocks belong to the
    /// target and stay.
    public func clearNamespaceState(targetId: String) throws {
        let tables = ["uploaded_manifest", "known_blob", "run_checkpoint", "snapshot_ledger"]
        try database.transaction {
            for table in tables {
                try database.run("DELETE FROM \(table) WHERE targetId = ?", [.text(targetId)])
            }
        }
    }

    // MARK: - What the target row shows, per SPEC 13.5

    /// The last failure and the last space query answer of one
    /// target.
    ///
    /// The row outlives the run that produced it, so the row state
    /// of 13.5 lives here and not in the run.
    public func targetStatus(targetId: String) throws -> TargetStatusRecord? {
        let rows = try database.query(
            """
            SELECT failureKind, failureDetail, failedAt, quotaUsed, quotaLimit, quotaAt
            FROM target_status WHERE targetId = ?
            """,
            [.text(targetId)])
        guard let row = rows.first else { return nil }
        func date(_ value: SQLiteValue) -> Date? {
            value.double.map { Date(timeIntervalSince1970: $0) }
        }
        let quota = row[3].int64.map {
            QuotaReading(usedBytes: $0, limitBytes: row[4].int64)
        }
        return TargetStatusRecord(
            targetId: targetId,
            failure: TargetFailure(kind: row[0].string, detail: row[1].string ?? ""),
            failedAt: date(row[2]),
            quota: quota,
            quotaAt: date(row[5]))
    }

    /// Writes the failure the last run left, or clears it after a
    /// run that reached the target.
    public func recordTargetFailure(
        targetId: String, failure: TargetFailure?, at date: Date
    ) throws {
        let kind: SQLiteValue = failure.map { .text($0.kind) } ?? .null
        let detail: SQLiteValue = failure.map { .text($0.detail) } ?? .null
        let when: SQLiteValue = failure == nil ? .null : .real(date.timeIntervalSince1970)
        try database.run(
            """
            INSERT INTO target_status (targetId, failureKind, failureDetail, failedAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId) DO UPDATE SET
                failureKind = excluded.failureKind,
                failureDetail = excluded.failureDetail,
                failedAt = excluded.failedAt
            """,
            [.text(targetId), kind, detail, when])
    }

    /// Writes the space query answer of 9.7. The add check and the
    /// re-sign-in check are the only callers, because Empo never
    /// polls a quota.
    public func recordTargetQuota(
        targetId: String, reading: QuotaReading?, at date: Date
    ) throws {
        let used: SQLiteValue = reading.map { .integer($0.usedBytes) } ?? .null
        let limit: SQLiteValue = reading?.limitBytes.map { .integer($0) } ?? .null
        let when: SQLiteValue = reading == nil ? .null : .real(date.timeIntervalSince1970)
        try database.run(
            """
            INSERT INTO target_status (targetId, quotaUsed, quotaLimit, quotaAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId) DO UPDATE SET
                quotaUsed = excluded.quotaUsed,
                quotaLimit = excluded.quotaLimit,
                quotaAt = excluded.quotaAt
            """,
            [.text(targetId), used, limit, when])
    }

    /// What Empo holds on one target, per game, biggest first.
    ///
    /// The newest manifest of each game names every file that game
    /// keeps there, so the sum is what the target holds now, not
    /// what every run ever uploaded.
    public func usage(targetId: String) throws -> [TargetGameUsage] {
        let rows = try database.query(
            "SELECT gameKey, manifest FROM uploaded_manifest WHERE targetId = ?",
            [.text(targetId)])
        var usage: [TargetGameUsage] = []
        for row in rows {
            guard let key = row[0].string, let payload = row[1].data,
                let manifest = try? SnapshotManifest.decode(json: payload)
            else { continue }
            usage.append(
                TargetGameUsage(
                    gameKey: key, bytes: manifest.entries.reduce(0) { $0 + $1.size }))
        }
        return usage.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.gameKey < $1.gameKey
        }
    }

    // MARK: - Maintenance clocks

    /// When the sweep of 5.11 last finished on this target.
    public func lastSweep(targetId: String) throws -> Date? {
        let rows = try database.query(
            "SELECT lastSweepAt FROM target_maintenance WHERE targetId = ?",
            [.text(targetId)])
        return rows.first?[0].double.map { Date(timeIntervalSince1970: $0) }
    }

    public func recordSweep(targetId: String, at date: Date) throws {
        try database.run(
            """
            INSERT INTO target_maintenance (targetId, lastSweepAt) VALUES (?, ?)
            ON CONFLICT (targetId) DO UPDATE SET lastSweepAt = excluded.lastSweepAt
            """,
            [.text(targetId), .real(date.timeIntervalSince1970)])
    }

    // MARK: - Targets

    /// Removes every row of one target. One database for every target
    /// makes this a `DELETE WHERE` instead of an `rm`, which is the
    /// price 6.2 names.
    public func removeTarget(targetId: String) throws {
        let tables = [
            "uploaded_manifest", "known_blob", "run_checkpoint", "snapshot_ledger",
            "target_maintenance", "target_status", "pending_deletion", "staleness", "run_record",
            "intent_record", "partial_tally",
        ]
        try database.transaction {
            for table in tables {
                try database.run("DELETE FROM \(table) WHERE targetId = ?", [.text(targetId)])
            }
        }
    }

    // MARK: - Helpers

    private func changeCount() throws -> Int {
        let rows = try database.query("SELECT changes()")
        return Int(rows.first?.first?.int64 ?? 0)
    }

    /// A short list of paths goes in one column as JSON. A row per
    /// path would buy nothing: nothing queries inside these lists.
    private static func encodeList(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private static func decodeList(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
