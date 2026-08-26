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
    public static let schemaVersion: Int32 = 1

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
            provenAt REAL NOT NULL,
            PRIMARY KEY (targetId, namespaceId, hash)
        );
        CREATE TABLE IF NOT EXISTS run_checkpoint (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            snapshotId TEXT NOT NULL,
            uploadedBytes INTEGER NOT NULL,
            pendingPaths TEXT NOT NULL,
            updatedAt REAL NOT NULL,
            PRIMARY KEY (targetId, gameKey)
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
            createdAt REAL NOT NULL,
            asked INTEGER NOT NULL
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

            for hash in SweepPlan.referencedHashes(in: [manifest]).sorted() {
                try database.run(
                    """
                    INSERT OR IGNORE INTO known_blob
                        (targetId, namespaceId, hash, provenAt)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        .text(targetId), .text(namespaceId), .text(hash),
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
                (targetId, gameKey, snapshotId, uploadedBytes, pendingPaths, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                pendingPaths = excluded.pendingPaths,
                updatedAt = excluded.updatedAt
            """,
            [
                .text(checkpoint.targetId), .text(checkpoint.gameKey),
                .text(checkpoint.snapshotId), .integer(checkpoint.uploadedBytes),
                .text(Self.encodeList(checkpoint.pendingPaths)),
                .real(checkpoint.updatedAt.timeIntervalSince1970),
            ])
    }

    public func checkpoint(targetId: String, gameKey: String) throws -> RunCheckpoint? {
        let rows = try database.query(
            """
            SELECT snapshotId, uploadedBytes, pendingPaths, updatedAt
            FROM run_checkpoint WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        guard let row = rows.first,
            let snapshotId = row[0].string,
            let uploadedBytes = row[1].int64,
            let paths = row[2].string,
            let updatedAt = row[3].double
        else { return nil }
        return RunCheckpoint(
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            uploadedBytes: uploadedBytes,
            pendingPaths: Self.decodeList(paths),
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
                (kind, targetId, gameKey, snapshotId, uploadedBytes, createdAt, asked)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind) DO UPDATE SET
                targetId = excluded.targetId,
                gameKey = excluded.gameKey,
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                createdAt = excluded.createdAt,
                asked = excluded.asked
            """,
            [
                .text(intent.kind.rawValue), .text(intent.targetId),
                intent.gameKey.map { .text($0) } ?? .null,
                intent.snapshotId.map { .text($0) } ?? .null,
                .integer(intent.uploadedBytes),
                .real(intent.createdAt.timeIntervalSince1970),
                .integer(intent.asked ? 1 : 0),
            ])
    }

    public func intent(kind: BackupIntentKind) throws -> BackupIntentRecord? {
        let rows = try database.query(
            """
            SELECT targetId, gameKey, snapshotId, uploadedBytes, createdAt, asked
            FROM intent_record WHERE kind = ?
            """,
            [.text(kind.rawValue)])
        guard let row = rows.first,
            let targetId = row[0].string,
            let uploadedBytes = row[3].int64,
            let createdAt = row[4].double,
            let asked = row[5].int64
        else { return nil }
        return BackupIntentRecord(
            kind: kind,
            targetId: targetId,
            gameKey: row[1].string,
            snapshotId: row[2].string,
            uploadedBytes: uploadedBytes,
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

    // MARK: - Targets

    /// Removes every row of one target. One database for every target
    /// makes this a `DELETE WHERE` instead of an `rm`, which is the
    /// price 6.2 names.
    public func removeTarget(targetId: String) throws {
        let tables = [
            "uploaded_manifest", "known_blob", "run_checkpoint",
            "pending_deletion", "staleness", "run_record", "intent_record",
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
