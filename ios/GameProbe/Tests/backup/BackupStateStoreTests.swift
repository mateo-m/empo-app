import Foundation
import XCTest

@testable import GameProbe

/// The local cache of SPEC 6.2, 6.3, 6.5, and 6.6.
final class BackupStateStoreTests: XCTestCase {

    private var tempRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_777_593_600)  // 2026-05-01T00:00:00Z
    private let targetId = "target-icloud"
    private let namespaceId = "3f2b9c1d4e5a6b7c8d9e0f1a2b3c4d5e"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private var databaseURL: URL {
        tempRoot.appendingPathComponent("state.sqlite")
    }

    private func makeStore() throws -> BackupStateStore {
        try BackupStateStore(url: nil)
    }

    private func manifest(
        containerFolderName: String = "Yume Nikki", hashes: [String]
    ) -> SnapshotManifest {
        SnapshotManifest(
            mode: .slim,
            containerFolderName: containerFolderName,
            entries: hashes.enumerated().map { index, hash in
                SnapshotManifest.Entry(
                    root: .container,
                    path: "Game/Save\(index).rvdata2",
                    size: 2048,
                    modifiedAt: now,
                    hash: hash,
                    compression: .zlib)
            })
    }

    private func hash(_ seed: String) -> String {
        ContentHash.hex(ofUTF8: seed)
    }

    // MARK: - Open, migrate, and rebuild, per 6.3

    func testAFreshDatabaseOpensUsableAndAsksForARebuild() throws {
        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .created)
        XCTAssertTrue(store.needsRebuildFromTarget)
        try store.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        XCTAssertEqual(try store.dirtyGames().count, 1)
    }

    func testReopeningTheSameSchemaKeepsTheRowsAndNeedsNoRebuild() throws {
        let first = try BackupStateStore(url: databaseURL)
        try first.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        first.close()

        let second = try BackupStateStore(url: databaseURL)
        defer { second.close() }

        XCTAssertEqual(second.openOutcome, .opened)
        XCTAssertFalse(second.needsRebuildFromTarget)
        XCTAssertEqual(try second.dirtyGames().map(\.gameKey), ["abc"])
    }

    func testAnOlderSchemaVersionRebuildsAndStaysUsable() throws {
        let first = try BackupStateStore(url: databaseURL)
        try first.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        first.close()

        // Version 5 migrates, so the oldest version without a
        // migration is 4.
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.setUserVersion(4)
        raw.close()

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .rebuilt(.schemaVersion(found: 4)))
        XCTAssertTrue(store.needsRebuildFromTarget)
        XCTAssertEqual(try store.dirtyGames(), [])
        try store.markDirty(gameKey: "def", targetIds: [targetId], at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["def"])
    }

    func testVersion5KeepsEachDirtyMarkForEveryTargetItKnows() throws {
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.execute(Self.version5Schema)
        try raw.execute(
            """
            INSERT INTO target_status (targetId) VALUES ('target-a');
            INSERT INTO staleness (targetId, gameKey) VALUES ('target-b', 'other');
            INSERT INTO dirty_game (gameKey, markedAt, reason) VALUES ('abc', 1000, 'play session');
            INSERT INTO intent_record (
                kind, targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                restoreScope, replacesTree, createdAt, asked)
            VALUES ('interrupted-restore', 'target-a', 'abc', 'snap', 0, 0, 'whole-game', 1, 1000, 0);
            INSERT INTO run_record VALUES ('open', 'target-a', 900, NULL, 'failed', 0, 0, 'closed early');
            INSERT INTO run_record VALUES ('done', 'target-a', 800, 860, 'partial', 10, 2, NULL);
            """)
        try raw.setUserVersion(5)
        raw.close()

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .opened)
        XCTAssertEqual(
            try store.dirtyGames(),
            [
                DirtyMark(
                    targetId: "target-a", gameKey: "abc",
                    markedAt: Date(timeIntervalSince1970: 1000)),
                DirtyMark(
                    targetId: "target-b", gameKey: "abc",
                    markedAt: Date(timeIntervalSince1970: 1000)),
            ])
        XCTAssertEqual(
            try store.intent(kind: .interruptedRestore)?.work,
            .restore(.replaceTheTree, movedAsideTree: nil))
        XCTAssertEqual(
            try store.runHistory(),
            [
                BackupRunRecord(
                    id: "open", targetId: "target-a", startedAt: Date(timeIntervalSince1970: 900)),
                BackupRunRecord(
                    id: "done", targetId: "target-a", startedAt: Date(timeIntervalSince1970: 800),
                    end: BackupRunEnd(outcome: .partial, finishedAt: Date(timeIntervalSince1970: 860)),
                    uploadedBytes: 10, gameCount: 2),
            ])
        let reopened = try BackupStateStore(url: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(reopened.openOutcome, .opened)
    }

    /// The schema of version 5, as devices hold it.
    private static let version5Schema = """
        CREATE TABLE IF NOT EXISTS uploaded_manifest (
            targetId TEXT NOT NULL,
            gameKey TEXT NOT NULL,
            snapshotId TEXT NOT NULL,
            manifest BLOB NOT NULL,
            uploadedAt REAL NOT NULL,
            PRIMARY KEY (targetId, gameKey)
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

    func testANewerSchemaVersionRebuildsToo() throws {
        // The cache is never truth, per 6.3, so a file from a newer
        // build is dropped rather than read half-understood.
        let first = try BackupStateStore(url: databaseURL)
        first.close()
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.setUserVersion(BackupStateStore.schemaVersion + 7)
        raw.close()

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(
            store.openOutcome,
            .rebuilt(.schemaVersion(found: BackupStateStore.schemaVersion + 7)))
    }

    func testACorruptFileRebuildsAndStaysUsable() throws {
        try Data("this is not a database, it is a photo".utf8).write(to: databaseURL)

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .rebuilt(.corrupt))
        XCTAssertTrue(store.needsRebuildFromTarget)
        try store.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["abc"])
    }

    func testAnEmptyFileRebuildsAndStaysUsable() throws {
        try Data().write(to: databaseURL)

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .created)
        try store.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["abc"])
    }

    // MARK: - The last uploaded manifest

    func testTheLastUploadedManifestComesBackWhole() throws {
        let store = try makeStore()
        defer { store.close() }
        let snapshot = manifest(hashes: [hash("one")])

        try store.recordUploadedManifest(
            snapshot, snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, uploadedAt: now)
        let record = try store.lastUploadedManifest(
            targetId: targetId, gameKey: snapshot.gameKey)

        XCTAssertEqual(record?.manifest, snapshot)
        XCTAssertEqual(record?.snapshotId, "20260501T000000Z-aabbcc")
        XCTAssertEqual(record?.uploadedAt, now)
    }

    func testASecondManifestReplacesTheFirstForThatGame() throws {
        let store = try makeStore()
        defer { store.close() }
        let first = manifest(hashes: [hash("one")])
        let second = manifest(hashes: [hash("one"), hash("two")])

        try store.recordUploadedManifest(
            first, snapshotId: "20260501T000000Z-aaaaaa",
            targetId: targetId, uploadedAt: now)
        try store.recordUploadedManifest(
            second, snapshotId: "20260502T000000Z-bbbbbb",
            targetId: targetId, uploadedAt: now.addingTimeInterval(86_400))

        let record = try store.lastUploadedManifest(
            targetId: targetId, gameKey: first.gameKey)
        XCTAssertEqual(record?.snapshotId, "20260502T000000Z-bbbbbb")
    }

    // MARK: - Checkpoints, dirty flags, and pending deletions

    func testACheckpointRoundTrips() throws {
        let store = try makeStore()
        defer { store.close() }
        let checkpoint = RunCheckpoint(
            targetId: targetId,
            gameKey: "abc",
            snapshotId: "20260501T000000Z-aabbcc",
            uploadedBytes: 4_194_304,
            pendingPaths: ["Game/Save1.rvdata2", "Game/Save2.rvdata2"],
            confirmedBlobs: [
                ConfirmedBlob(hash: hash("one"), compression: .zlib),
                ConfirmedBlob(hash: hash("two"), compression: .stored),
            ],
            updatedAt: now)

        try store.saveCheckpoint(checkpoint)

        XCTAssertEqual(try store.checkpoint(targetId: targetId, gameKey: "abc"), checkpoint)
        try store.clearCheckpoint(targetId: targetId, gameKey: "abc")
        XCTAssertNil(try store.checkpoint(targetId: targetId, gameKey: "abc"))
    }

    func testAConfirmedBlobReadsBackAsText() {
        let blob = ConfirmedBlob(hash: hash("one"), compression: .zlib)

        XCTAssertEqual(ConfirmedBlob(text: blob.text), blob)
        XCTAssertNil(ConfirmedBlob(text: hash("one")))
        XCTAssertNil(ConfirmedBlob(text: "\(hash("one")):brotli"))
    }

    func testADirtyGameClears() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        try store.markDirty(gameKey: "def", targetIds: [targetId], at: now)
        try store.clearDirty(targetId: targetId, gameKey: "abc", markedUpTo: now)

        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["def"])
    }

    func testClearingOneTargetKeepsTheMarkOfTheOther() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.markDirty(gameKey: "abc", targetIds: ["target-a", "target-b"], at: now)
        try store.clearDirty(targetId: "target-a", gameKey: "abc", markedUpTo: now)

        XCTAssertEqual(
            try store.dirtyGames(), [DirtyMark(targetId: "target-b", gameKey: "abc", markedAt: now)])
    }

    func testADirtyMarkAfterTheScanStays() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.markDirty(gameKey: "abc", targetIds: [targetId], at: now)
        try store.clearDirty(
            targetId: targetId, gameKey: "abc", markedUpTo: now.addingTimeInterval(-1))

        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["abc"])
    }

    func testAPendingDeletionWaitsForTheNextRun() throws {
        let store = try makeStore()
        defer { store.close() }
        let deletion = PendingDeletion(
            targetId: targetId,
            gameKey: "abc",
            requestedAt: now,
            rescuedBuckets: ["Yume Nikki (rescued)"])

        try store.addPendingDeletion(deletion)

        XCTAssertEqual(try store.pendingDeletions(targetId: targetId), [deletion])
        try store.clearPendingDeletion(targetId: targetId, gameKey: "abc")
        XCTAssertEqual(try store.pendingDeletions(targetId: targetId), [])
    }

    func testAStalenessClockRoundTripsWithItsEmptyFields() throws {
        let store = try makeStore()
        defer { store.close() }
        let clock = StalenessClock(
            targetId: targetId, gameKey: "abc",
            lastSuccessAt: now, lastAttemptAt: now.addingTimeInterval(3600))

        try store.saveStaleness(clock)
        let read = try store.staleness(targetId: targetId, gameKey: "abc")

        XCTAssertEqual(read, clock)
        XCTAssertNil(read?.partialSince)
    }

    func testRemovingATargetLeavesTheOtherTargetAlone() throws {
        let store = try makeStore()
        defer { store.close() }
        let snapshot = manifest(hashes: [hash("one")])
        for target in [targetId, "target-dropbox"] {
            try store.recordUploadedManifest(
                snapshot, snapshotId: "20260501T000000Z-aabbcc",
                targetId: target, uploadedAt: now)
        }

        try store.removeTarget(targetId: targetId)

        XCTAssertNil(
            try store.lastUploadedManifest(targetId: targetId, gameKey: snapshot.gameKey))
        XCTAssertNotNil(
            try store.lastUploadedManifest(
                targetId: "target-dropbox", gameKey: snapshot.gameKey))
    }

    // MARK: - Intent records, per 6.5

    func testTheIntentRecordsSurviveACloseAndAReopen() throws {
        let records = [
            BackupIntentRecord(
                targetId: targetId, gameKey: "def",
                work: .run(uploadedBytes: 250 * 1024 * 1024, remainingBytes: 1024), createdAt: now),
            BackupIntentRecord(
                targetId: targetId, gameKey: "ghi",
                work: .restore(.replaceTheTree, movedAsideTree: "Game (replaced)"), createdAt: now),
        ]

        let first = try BackupStateStore(url: databaseURL)
        for record in records {
            try first.saveIntent(record)
        }
        first.close()

        let second = try BackupStateStore(url: databaseURL)
        defer { second.close() }
        for record in records {
            XCTAssertEqual(try second.intent(kind: record.kind), record)
        }
    }

    func testARestoreRecordKeepsItsScope() throws {
        let store = try makeStore()
        defer { store.close() }
        let record = BackupIntentRecord(
            targetId: targetId, gameKey: "jkl",
            work: .restore(.restore(.savesAndSettings), movedAsideTree: nil), createdAt: now)

        try store.saveIntent(record)

        XCTAssertEqual(try store.intent(kind: .interruptedRestore), record)
    }

    func testTheResumeQuestionFloorIs100MB() {
        XCTAssertEqual(BackupIntentRecord.resumeQuestionFloorBytes, 100 * 1024 * 1024)
    }

    func testAnInterruptedRunUnderTheFloorRecoversSilently() {
        let record = BackupIntentRecord(
            targetId: targetId,
            work: .run(uploadedBytes: BackupIntentRecord.resumeQuestionFloorBytes - 1, remainingBytes: 0),
            createdAt: now)

        XCTAssertFalse(record.asksAtNextLaunch)
    }

    func testAnInterruptedRunAtTheFloorAsks() {
        let record = BackupIntentRecord(
            targetId: targetId,
            work: .run(uploadedBytes: BackupIntentRecord.resumeQuestionFloorBytes, remainingBytes: 0),
            createdAt: now)

        XCTAssertTrue(record.asksAtNextLaunch)
    }

    func testAnInterruptedRestoreAsksWhateverItsSize() {
        let record = BackupIntentRecord(
            targetId: targetId, work: .restore(.restore(.wholeGame), movedAsideTree: nil),
            createdAt: now)

        XCTAssertTrue(record.asksAtNextLaunch)
    }

    func testTheSameInterruptionNeverAsksTwice() throws {
        let store = try BackupStateStore(url: databaseURL)
        try store.saveIntent(
            BackupIntentRecord(
                targetId: targetId,
                work: .run(uploadedBytes: 250 * 1024 * 1024, remainingBytes: 0), createdAt: now))
        XCTAssertEqual(try store.intent(kind: .interruptedRun)?.asksAtNextLaunch, true)

        try store.markIntentAsked(kind: .interruptedRun)
        store.close()

        let second = try BackupStateStore(url: databaseURL)
        defer { second.close() }
        XCTAssertEqual(try second.intent(kind: .interruptedRun)?.asked, true)
        XCTAssertEqual(try second.intent(kind: .interruptedRun)?.asksAtNextLaunch, false)
    }

    func testClearingAnIntentLeavesTheOtherKinds() throws {
        let store = try makeStore()
        defer { store.close() }
        try store.saveIntent(
            BackupIntentRecord(
                targetId: targetId, work: .run(uploadedBytes: 0, remainingBytes: 0), createdAt: now))
        try store.saveIntent(
            BackupIntentRecord(
                targetId: targetId, work: .restore(.restore(.wholeGame), movedAsideTree: nil),
                createdAt: now))

        try store.clearIntent(kind: .interruptedRun)

        XCTAssertNil(try store.intent(kind: .interruptedRun))
        XCTAssertNotNil(try store.intent(kind: .interruptedRestore))
    }

    // MARK: - Run history, per 6.6

    private func run(_ id: String, daysAgo: Double, outcome: BackupRunOutcome) -> BackupRunRecord {
        BackupRunRecord(
            id: id,
            targetId: targetId,
            startedAt: now.addingTimeInterval(-daysAgo * 86_400),
            end: BackupRunEnd(
                outcome: outcome, finishedAt: now.addingTimeInterval(-daysAgo * 86_400 + 60),
                detail: outcome == .failed ? "the target refused the write" : nil),
            uploadedBytes: 2048,
            gameCount: 3)
    }

    func testTheRetentionIs90Days() {
        XCTAssertEqual(BackupRunRecord.retention, 90 * 86_400)
    }

    func testANewRunDropsARowPast90DaysAndKeepsOneAt89() throws {
        let store = try makeStore()
        defer { store.close() }
        try store.recordRun(run("old", daysAgo: 91, outcome: .success))
        try store.recordRun(run("edge", daysAgo: 89, outcome: .success))

        try store.recordRun(run("new", daysAgo: 0, outcome: .success))

        XCTAssertEqual(try store.runHistory().map(\.id), ["new", "edge"])
    }

    func testAFailedRunKeepsItsLine() throws {
        // The row is the only written record of a transient failure,
        // which is what makes the quiet-failure rule of 7.11 safe.
        let store = try makeStore()
        defer { store.close() }

        try store.recordRun(run("failed", daysAgo: 1, outcome: .failed))

        let record = try store.runHistory().first
        XCTAssertEqual(record?.end?.outcome, .failed)
        XCTAssertEqual(record?.end?.detail, "the target refused the write")
    }

    func testRunHistoryIsOneGlobalListNewestFirst() throws {
        let store = try makeStore()
        defer { store.close() }
        try store.recordRun(run("older", daysAgo: 3, outcome: .success))
        try store.recordRun(run("newer", daysAgo: 1, outcome: .partial))
        var other = run("other-target", daysAgo: 2, outcome: .success)
        other.targetId = "target-dropbox"
        try store.recordRun(other)

        XCTAssertEqual(
            try store.runHistory().map(\.id), ["newer", "other-target", "older"])
    }

    func testRecordingTheSameRunAgainUpdatesItsRow() throws {
        let store = try makeStore()
        defer { store.close() }
        var record = run("live", daysAgo: 0, outcome: .success)
        record.end = nil
        try store.recordRun(record)
        XCTAssertEqual(try store.runHistory(), [record])

        record.end = BackupRunEnd(outcome: .failed, finishedAt: now, detail: "the network went away")
        try store.recordRun(record)

        XCTAssertEqual(try store.runHistory(), [record])
    }
    // MARK: - The scheduler's own state, per SPEC 7.10 and 7.11

    func testTheInterruptedRunTallySurvivesAReopen() throws {
        let first = try BackupStateStore(url: databaseURL)
        XCTAssertEqual(try first.interruptedRunTally().count, 0)
        try first.saveInterruptedRunTally(InterruptedRunTally(count: 3))
        first.close()

        let second = try BackupStateStore(url: databaseURL)
        defer { second.close() }
        XCTAssertEqual(try second.interruptedRunTally().count, 3)
    }

    func testTheNotificationLedgerRoundTrips() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        XCTAssertEqual(try store.notificationLedger(), BackupNotificationLedger())
        var ledger = BackupNotificationLedger()
        _ = ledger.post(causes: [.signInDead], targetId: "t1")
        _ = ledger.post(causes: [.deviceStorageLow], targetId: "t2")
        try store.saveNotificationLedger(ledger)
        XCTAssertEqual(try store.notificationLedger(), ledger)
    }

    func testThePartialTallyReplacesRatherThanMerges() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.savePartialTally(
            ["Game/a.rvdata2": 2, "Game/b.rvdata2": 1], targetId: "t1", gameKey: "g")
        XCTAssertEqual(
            try store.partialTally(targetId: "t1", gameKey: "g"),
            ["Game/a.rvdata2": 2, "Game/b.rvdata2": 1])
        try store.savePartialTally(["Game/a.rvdata2": 3], targetId: "t1", gameKey: "g")
        XCTAssertEqual(
            try store.partialTally(targetId: "t1", gameKey: "g"), ["Game/a.rvdata2": 3])
    }

    func testRemovingATargetDropsItsPartialTally() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.savePartialTally(["Game/a.rvdata2": 2], targetId: "t1", gameKey: "g")
        try store.removeTarget(targetId: "t1")
        XCTAssertEqual(try store.partialTally(targetId: "t1", gameKey: "g"), [:])
    }

    // MARK: - What the target row shows, per 13.5 and 13.6

    func testATargetFailureOutlivesTheRunThatLeftIt() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordTargetFailure(
            targetId: "t1", failure: .blockedByPermissions(reason: "no write right"), at: now)
        let status = try store.targetStatus(targetId: "t1")
        XCTAssertEqual(status?.failure, .blockedByPermissions(reason: "no write right"))
        XCTAssertEqual(status?.failedAt, now)
    }

    func testTheStoreKeepsWhyATargetWasUnreachable() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        for cause in [UnreachableCause.noAnswer, .serverError, .busy] {
            try store.recordTargetFailure(targetId: "t1", failure: .unreachable(cause), at: now)
            XCTAssertEqual(try store.targetStatus(targetId: "t1")?.failure, .unreachable(cause))
        }
    }

    func testARunThatReachesTheTargetClearsTheFailure() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordTargetFailure(targetId: "t1", failure: .unreachable(), at: now)
        try store.recordTargetFailure(targetId: "t1", failure: nil, at: now)
        let status = try store.targetStatus(targetId: "t1")
        XCTAssertNil(status?.failure)
        XCTAssertNil(status?.failedAt)
    }

    func testTheSpaceQueryAnswerAndTheFailureKeepTheirOwnColumns() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordTargetQuota(
            targetId: "t1", reading: QuotaReading(usedBytes: 400, limitBytes: 1_000), at: now)
        try store.recordTargetFailure(targetId: "t1", failure: .needsSignIn, at: now)
        let status = try store.targetStatus(targetId: "t1")
        XCTAssertEqual(status?.quota, QuotaReading(usedBytes: 400, limitBytes: 1_000))
        XCTAssertEqual(status?.quotaAt, now)
        XCTAssertEqual(status?.failure, .needsSignIn)
    }

    func testUsageSumsTheNewestManifestOfEachGameBiggestFirst() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordUploadedManifest(
            manifest(containerFolderName: "Yume Nikki", hashes: [hash("a")]),
            snapshotId: "s1", targetId: "t1", uploadedAt: now)
        try store.recordUploadedManifest(
            manifest(containerFolderName: "Ib", hashes: [hash("b"), hash("c")]),
            snapshotId: "s2", targetId: "t1", uploadedAt: now)
        XCTAssertEqual(
            try store.usage(targetId: "t1"),
            [
                TargetGameUsage(
                    gameKey: BackupKeys.gameKey(containerFolderName: "Ib"), bytes: 4096),
                TargetGameUsage(
                    gameKey: BackupKeys.gameKey(containerFolderName: "Yume Nikki"), bytes: 2048),
            ])
    }

    func testRemovingATargetDropsItsStatus() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordTargetFailure(targetId: "t1", failure: .needsSignIn, at: now)
        try store.removeTarget(targetId: "t1")
        XCTAssertNil(try store.targetStatus(targetId: "t1"))
    }

    /// `removeTarget` derives its table list from the schema, so a
    /// table added later is covered. This writes one row into every
    /// table that files rows under a target, then reads them all
    /// back empty.
    func testRemovingATargetEmptiesEveryTableThatFilesRowsUnderIt() throws {
        let store = try makeStore()
        defer { store.close() }
        let snapshot = manifest(hashes: [hash("one")])
        let gameKey = snapshot.gameKey

        try store.recordUploadedManifest(
            snapshot, snapshotId: "s1", targetId: targetId, uploadedAt: now)
        try store.saveCheckpoint(
            RunCheckpoint(
                targetId: targetId, gameKey: gameKey, snapshotId: "s1", uploadedBytes: 1,
                pendingPaths: ["Game/Save0.rvdata2"], confirmedBlobs: [], updatedAt: now))
        try store.recordSnapshot(
            SnapshotLedgerEntry(
                targetId: targetId, gameKey: gameKey, snapshotId: "s1", createdAt: now))
        try store.recordSweep(targetId: targetId, at: now)
        try store.recordTargetFailure(targetId: targetId, failure: .needsSignIn, at: now)
        try store.addPendingDeletion(
            PendingDeletion(targetId: targetId, gameKey: gameKey, requestedAt: now))
        try store.saveStaleness(
            StalenessClock(targetId: targetId, gameKey: gameKey, lastSuccessAt: now))
        try store.recordRun(
            BackupRunRecord(
                id: "r1", targetId: targetId, startedAt: now,
                end: BackupRunEnd(outcome: .success, finishedAt: now)))
        try store.saveIntent(
            BackupIntentRecord(
                targetId: targetId, gameKey: gameKey,
                work: .run(uploadedBytes: 0, remainingBytes: 0), createdAt: now))
        try store.savePartialTally(
            ["Game/Save0.rvdata2": 2], targetId: targetId, gameKey: gameKey)

        try store.removeTarget(targetId: targetId)

        XCTAssertNil(try store.lastUploadedManifest(targetId: targetId, gameKey: gameKey))
        XCTAssertNil(try store.checkpoint(targetId: targetId, gameKey: gameKey))
        XCTAssertEqual(try store.snapshots(targetId: targetId, gameKey: gameKey), [])
        XCTAssertNil(try store.lastSweep(targetId: targetId))
        XCTAssertNil(try store.targetStatus(targetId: targetId))
        XCTAssertEqual(try store.pendingDeletions(targetId: targetId), [])
        XCTAssertNil(try store.staleness(targetId: targetId, gameKey: gameKey))
        XCTAssertEqual(try store.runHistory(), [])
        XCTAssertNil(try store.intent(kind: .interruptedRun))
        XCTAssertEqual(try store.partialTally(targetId: targetId, gameKey: gameKey), [:])
    }
}
