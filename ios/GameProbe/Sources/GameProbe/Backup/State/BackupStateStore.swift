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

    let database: SQLiteDatabase

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


    // MARK: - Deleting a target and a namespace

    /// Every table that files its rows under a target.
    ///
    /// SQLite answers this from the schema, so a table added later
    /// is covered without an edit here. `removeTarget` must leave no
    /// row behind, and a hand-kept list is one merge away from
    /// missing a table.
    private func targetScopedTables() throws -> [String] {
        let rows = try database.query(
            """
            SELECT m.name FROM sqlite_master AS m
            JOIN pragma_table_info(m.name) AS c
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND c.name = 'targetId'
            ORDER BY m.name
            """)
        return rows.compactMap { $0.first?.string }
    }

    /// The tables that describe what one device namespace holds.
    ///
    /// This one is a choice and not a fact about the schema. The run
    /// history and the staleness clocks belong to the target and
    /// stay, per the split of 5.12.
    private static let namespaceScopedTables = [
        "uploaded_manifest", "known_blob", "run_checkpoint", "snapshot_ledger",
    ]

    /// Drops every row that describes what one namespace holds.
    ///
    /// The split of 5.12 calls it. No namespace may reference
    /// another's blobs, so the new namespace starts from a full
    /// upload, and every row that would suppress an upload has to
    /// go.
    public func clearNamespaceState(targetId: String) throws {
        try delete(targetId: targetId, from: Self.namespaceScopedTables)
    }

    /// Removes every row of one target. One database for every target
    /// makes this a `DELETE WHERE` instead of an `rm`, which is the
    /// price 6.2 names.
    public func removeTarget(targetId: String) throws {
        try delete(targetId: targetId, from: try targetScopedTables())
    }

    private func delete(targetId: String, from tables: [String]) throws {
        try database.transaction {
            for table in tables {
                try database.run("DELETE FROM \(table) WHERE targetId = ?", [.text(targetId)])
            }
        }
    }

    // MARK: - Helpers

    func changeCount() throws -> Int {
        let rows = try database.query("SELECT changes()")
        return Int(rows.first?.first?.int64 ?? 0)
    }

    /// A short list of paths goes in one column as JSON. A row per
    /// path would buy nothing: nothing queries inside these lists.
    static func encodeList(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    static func decodeList(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
