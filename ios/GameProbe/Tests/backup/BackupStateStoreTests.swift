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
        try store.markDirty(gameKey: "abc", reason: "import", at: now)
        XCTAssertEqual(try store.dirtyGames().count, 1)
    }

    func testReopeningTheSameSchemaKeepsTheRowsAndNeedsNoRebuild() throws {
        let first = try BackupStateStore(url: databaseURL)
        try first.markDirty(gameKey: "abc", reason: "import", at: now)
        first.close()

        let second = try BackupStateStore(url: databaseURL)
        defer { second.close() }

        XCTAssertEqual(second.openOutcome, .opened)
        XCTAssertFalse(second.needsRebuildFromTarget)
        XCTAssertEqual(try second.dirtyGames().map(\.gameKey), ["abc"])
    }

    func testAnOlderSchemaVersionRebuildsAndStaysUsable() throws {
        let first = try BackupStateStore(url: databaseURL)
        try first.markDirty(gameKey: "abc", reason: "import", at: now)
        first.close()

        // Put the file back on an older version, the way a downgrade
        // and an upgrade both leave it.
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.setUserVersion(BackupStateStore.schemaVersion - 1)
        raw.close()

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(
            store.openOutcome,
            .rebuilt(.schemaVersion(found: BackupStateStore.schemaVersion - 1)))
        XCTAssertTrue(store.needsRebuildFromTarget)
        XCTAssertEqual(try store.dirtyGames(), [])
        try store.markDirty(gameKey: "def", reason: "runtime watch", at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["def"])
    }

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
        try store.markDirty(gameKey: "abc", reason: "import", at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["abc"])
    }

    func testAnEmptyFileRebuildsAndStaysUsable() throws {
        try Data().write(to: databaseURL)

        let store = try BackupStateStore(url: databaseURL)
        defer { store.close() }

        XCTAssertEqual(store.openOutcome, .created)
        try store.markDirty(gameKey: "abc", reason: "import", at: now)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["abc"])
    }

    // MARK: - Known blobs, per 6.2

    func testABlobIsNotKnownPresentUntilItsManifestUploads() throws {
        let store = try makeStore()
        defer { store.close() }
        let blob = hash("save bytes")
        let snapshot = manifest(hashes: [blob])

        // The blob itself may already be on the target. Its existence
        // is not proven until the manifest that names it succeeds.
        XCTAssertFalse(
            try store.isBlobKnownPresent(
                hash: blob, targetId: targetId, namespaceId: namespaceId))

        try store.recordUploadedManifest(
            snapshot, snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)

        XCTAssertTrue(
            try store.isBlobKnownPresent(
                hash: blob, targetId: targetId, namespaceId: namespaceId))
    }

    func testAKnownBlobIsScopedToItsTargetAndNamespace() throws {
        let store = try makeStore()
        defer { store.close() }
        let blob = hash("save bytes")

        try store.recordUploadedManifest(
            manifest(hashes: [blob]), snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)

        XCTAssertFalse(
            try store.isBlobKnownPresent(
                hash: blob, targetId: "target-dropbox", namespaceId: namespaceId))
        XCTAssertFalse(
            try store.isBlobKnownPresent(
                hash: blob, targetId: targetId, namespaceId: "another-device"))
    }

    func testEveryHashOfTheManifestBecomesKnown() throws {
        let store = try makeStore()
        defer { store.close() }
        let hashes = [hash("one"), hash("two"), hash("three")]

        try store.recordUploadedManifest(
            manifest(hashes: hashes), snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)

        XCTAssertEqual(
            try store.knownBlobHashes(targetId: targetId, namespaceId: namespaceId),
            Set(hashes))
    }

    func testAKnownBlobCarriesTheAlgorithmItWentUpWith() throws {
        let store = try makeStore()
        defer { store.close() }
        var snapshot = manifest(hashes: [hash("one"), hash("two")])
        snapshot.entries[1].compression = .stored

        try store.recordUploadedManifest(
            snapshot, snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)

        // The hash names the content, and 5.6 chooses the algorithm
        // per blob, so a run that reuses a blob has to read back
        // what the blob holds.
        XCTAssertEqual(
            try store.knownBlobCompression(
                hash: hash("one"), targetId: targetId, namespaceId: namespaceId),
            .zlib)
        XCTAssertEqual(
            try store.knownBlobCompression(
                hash: hash("two"), targetId: targetId, namespaceId: namespaceId),
            .stored)
        XCTAssertNil(
            try store.knownBlobCompression(
                hash: hash("three"), targetId: targetId, namespaceId: namespaceId))
    }

    func testTheLastUploadedManifestComesBackWhole() throws {
        let store = try makeStore()
        defer { store.close() }
        let snapshot = manifest(hashes: [hash("one")])

        try store.recordUploadedManifest(
            snapshot, snapshotId: "20260501T000000Z-aabbcc",
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)
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
            targetId: targetId, namespaceId: namespaceId, uploadedAt: now)
        try store.recordUploadedManifest(
            second, snapshotId: "20260502T000000Z-bbbbbb",
            targetId: targetId, namespaceId: namespaceId,
            uploadedAt: now.addingTimeInterval(86_400))

        let record = try store.lastUploadedManifest(
            targetId: targetId, gameKey: first.gameKey)
        XCTAssertEqual(record?.snapshotId, "20260502T000000Z-bbbbbb")
        // The older manifest's blobs stay known. Deleting a manifest
        // frees no space, per invariant 1.1.6.
        XCTAssertEqual(
            try store.knownBlobHashes(targetId: targetId, namespaceId: namespaceId).count, 2)
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

        try store.markDirty(gameKey: "abc", reason: "mode change", at: now)
        try store.markDirty(gameKey: "def", reason: "runtime watch", at: now)
        try store.clearDirty(gameKey: "abc")

        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), ["def"])
        XCTAssertEqual(try store.dirtyGames().first?.reason, "runtime watch")
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
                targetId: target, namespaceId: namespaceId, uploadedAt: now)
        }

        try store.removeTarget(targetId: targetId)

        XCTAssertNil(
            try store.lastUploadedManifest(targetId: targetId, gameKey: snapshot.gameKey))
        XCTAssertEqual(
            try store.knownBlobHashes(targetId: targetId, namespaceId: namespaceId), [])
        XCTAssertNotNil(
            try store.lastUploadedManifest(
                targetId: "target-dropbox", gameKey: snapshot.gameKey))
    }

    // MARK: - Intent records, per 6.5

    func testTheThreeIntentRecordsSurviveACloseAndAReopen() throws {
        let records = [
            BackupIntentRecord(
                kind: .pausedRun, targetId: targetId, gameKey: "abc",
                snapshotId: "20260501T000000Z-aabbcc", uploadedBytes: 1024, createdAt: now),
            BackupIntentRecord(
                kind: .interruptedRun, targetId: targetId, gameKey: "def",
                uploadedBytes: 250 * 1024 * 1024, createdAt: now),
            BackupIntentRecord(
                kind: .interruptedRestore, targetId: targetId, gameKey: "ghi",
                createdAt: now),
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

    func testTheResumeQuestionFloorIs100MB() {
        XCTAssertEqual(BackupIntentRecord.resumeQuestionFloorBytes, 100 * 1024 * 1024)
    }

    func testAnInterruptedRunUnderTheFloorRecoversSilently() {
        let record = BackupIntentRecord(
            kind: .interruptedRun, targetId: targetId,
            uploadedBytes: BackupIntentRecord.resumeQuestionFloorBytes - 1, createdAt: now)

        XCTAssertFalse(record.asksAtNextLaunch)
    }

    func testAnInterruptedRunAtTheFloorAsks() {
        let record = BackupIntentRecord(
            kind: .interruptedRun, targetId: targetId,
            uploadedBytes: BackupIntentRecord.resumeQuestionFloorBytes, createdAt: now)

        XCTAssertTrue(record.asksAtNextLaunch)
    }

    func testAPausedRunNeverAsksAtLaunch() {
        // Resume is one tap while the process lives, per 6.5.
        let record = BackupIntentRecord(
            kind: .pausedRun, targetId: targetId,
            uploadedBytes: 900 * 1024 * 1024, createdAt: now)

        XCTAssertFalse(record.asksAtNextLaunch)
    }

    func testAnInterruptedRestoreAsksWhateverItsSize() {
        let record = BackupIntentRecord(
            kind: .interruptedRestore, targetId: targetId, uploadedBytes: 0, createdAt: now)

        XCTAssertTrue(record.asksAtNextLaunch)
    }

    func testTheSameInterruptionNeverAsksTwice() throws {
        let store = try BackupStateStore(url: databaseURL)
        try store.saveIntent(
            BackupIntentRecord(
                kind: .interruptedRun, targetId: targetId,
                uploadedBytes: 250 * 1024 * 1024, createdAt: now))
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
            BackupIntentRecord(kind: .pausedRun, targetId: targetId, createdAt: now))
        try store.saveIntent(
            BackupIntentRecord(kind: .interruptedRestore, targetId: targetId, createdAt: now))

        try store.clearIntent(kind: .pausedRun)

        XCTAssertNil(try store.intent(kind: .pausedRun))
        XCTAssertNotNil(try store.intent(kind: .interruptedRestore))
    }

    // MARK: - Run history, per 6.6

    private func run(_ id: String, daysAgo: Double, outcome: BackupRunOutcome) -> BackupRunRecord {
        BackupRunRecord(
            id: id,
            targetId: targetId,
            startedAt: now.addingTimeInterval(-daysAgo * 86_400),
            finishedAt: now.addingTimeInterval(-daysAgo * 86_400 + 60),
            outcome: outcome,
            uploadedBytes: 2048,
            gameCount: 3,
            detail: outcome == .failed ? "the target refused the write" : nil)
    }

    func testTheRetentionIs90Days() {
        XCTAssertEqual(BackupRunRecord.retention, 90 * 86_400)
    }

    func testRunHistoryDropsARowPast90DaysAndKeepsOneAt89() throws {
        let store = try makeStore()
        defer { store.close() }
        try store.recordRun(run("old", daysAgo: 91, outcome: .success))
        try store.recordRun(run("edge", daysAgo: 89, outcome: .success))

        let dropped = try store.pruneRunHistory(now: now)

        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(try store.runHistory().map(\.id), ["edge"])
    }

    func testAFailedRunKeepsItsLine() throws {
        // The row is the only written record of a transient failure,
        // which is what makes the quiet-failure rule of 7.11 safe.
        let store = try makeStore()
        defer { store.close() }

        try store.recordRun(run("failed", daysAgo: 1, outcome: .failed))

        let record = try store.runHistory().first
        XCTAssertEqual(record?.outcome, .failed)
        XCTAssertEqual(record?.detail, "the target refused the write")
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
        record.finishedAt = nil
        try store.recordRun(record)

        record.finishedAt = now
        record.outcome = .failed
        record.detail = "the network went away"
        try store.recordRun(record)

        XCTAssertEqual(try store.runHistory(), [record])
    }
    // MARK: - The scheduler's own state, per SPEC 7.10 and 7.11

    func testTheInterruptedRunTallySurvivesAReopen() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        XCTAssertEqual(try store.interruptedRunTally().count, 0)
        try store.saveInterruptedRunTally(InterruptedRunTally(count: 3))
        XCTAssertEqual(try store.interruptedRunTally().count, 3)
        try store.saveInterruptedRunTally(InterruptedRunTally(count: 0))
        XCTAssertEqual(try store.interruptedRunTally().count, 0)
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

    func testARunThatReachesTheTargetClearsTheFailure() throws {
        let store = try BackupStateStore(url: nil)
        defer { store.close() }
        try store.recordTargetFailure(targetId: "t1", failure: .unreachable, at: now)
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
            snapshotId: "s1", targetId: "t1", namespaceId: namespaceId, uploadedAt: now)
        try store.recordUploadedManifest(
            manifest(containerFolderName: "Ib", hashes: [hash("b"), hash("c")]),
            snapshotId: "s2", targetId: "t1", namespaceId: namespaceId, uploadedAt: now)
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
            snapshot, snapshotId: "s1", targetId: targetId, namespaceId: namespaceId,
            uploadedAt: now)
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
                id: "r1", targetId: targetId, startedAt: now, finishedAt: now,
                outcome: .success))
        try store.saveIntent(
            BackupIntentRecord(
                kind: .interruptedRun, targetId: targetId, gameKey: gameKey, createdAt: now))
        try store.savePartialTally(
            ["Game/Save0.rvdata2": 2], targetId: targetId, gameKey: gameKey)

        try store.removeTarget(targetId: targetId)

        XCTAssertNil(try store.lastUploadedManifest(targetId: targetId, gameKey: gameKey))
        XCTAssertEqual(try store.knownBlobHashes(targetId: targetId, namespaceId: namespaceId), [])
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
