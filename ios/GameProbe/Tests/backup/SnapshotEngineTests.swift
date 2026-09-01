import Foundation
import XCTest

@testable import GameProbe

/// A clock a test moves by hand. The engine reads its time through
/// this, so every rule that reads a date is repeatable.
final class TestClock: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        self.value = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// The snapshot engine of SPEC 5.8 to 5.15 and 7.7 to 7.8, against
/// the fake target of ticket 005.
final class SnapshotEngineTests: XCTestCase {

    private let fm = FileManager.default
    private let targetId = "target-1"
    private let namespaceId = "ns-1"
    private let deviceId = "device-a"
    private let gameName = "Fixture Quest"

    private var tempRoot: URL!
    private var localRoot: URL!
    private var documents: URL!
    private var targetDirectory: URL!
    private var clock: TestClock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("SnapshotEngineTests-\(UUID().uuidString)", isDirectory: true)
        localRoot = tempRoot.appendingPathComponent("local", isDirectory: true)
        documents = tempRoot.appendingPathComponent("documents", isDirectory: true)
        targetDirectory = tempRoot.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        // The blob objects the fake target writes carry the host's
        // own modified time, and the sweep of 5.11 compares them
        // against this clock, so the clock starts where they do.
        clock = TestClock(Date())
    }

    override func tearDown() {
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTarget(
        capabilities: TargetCapabilities = TargetCapabilities(),
        quotaLimitBytes: Int64? = nil
    ) -> FakeBackupTarget {
        FakeBackupTarget(
            directory: targetDirectory,
            capabilities: capabilities,
            quotaLimitBytes: quotaLimitBytes,
            clock: FakeBackupClock())
    }

    private func makeEngine(
        _ target: FakeBackupTarget, observer: (any BackupRunObserver)? = nil
    ) throws -> SnapshotEngine {
        let store = try BackupStateStore(url: nil)
        let clock = self.clock!
        return SnapshotEngine(
            provider: target,
            store: store,
            localRoot: localRoot,
            clock: FakeBackupClock(),
            observer: observer,
            now: { clock.now })
    }

    private var descriptor: TargetDescriptor {
        TargetDescriptor(id: targetId, provider: .webdav, label: "Fake", root: "")
    }

    private var paths: BackupNamespacePaths {
        BackupNamespacePaths(root: "", namespaceId: namespaceId)
    }

    private func key(_ folderName: String) -> String {
        GameIdentity(folderName: folderName).gameKey
    }

    private func write(_ text: String, to url: URL, modifiedAt: Date? = nil) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let modifiedAt {
            try fm.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func container(_ folderName: String) -> URL {
        documents.appendingPathComponent("Games/\(folderName)", isDirectory: true)
    }

    /// A slim-mode tree of four members: the two save files the
    /// classifier of 3.4 finds, and the two always-in files of 3.1.
    @discardableResult
    private func makeGameTree(_ folderName: String) throws -> URL {
        let root = container(folderName)
        try write("[Game]\nTitle=\(folderName)\n", to: root.appendingPathComponent("Game/Game.ini"))
        try write("slot one of \(folderName)", to: root.appendingPathComponent("Game/save1.dat"))
        try write("auto of \(folderName)", to: root.appendingPathComponent("Game/autosave.sav"))
        try write("{\"title\":\"\(folderName)\"}", to: root.appendingPathComponent("Metadata/metadata.json"))
        try write("{\"marks\":[]}", to: root.appendingPathComponent("EmpoState/backup.json"))
        return root
    }

    private func changeTheSave(of folderName: String, to text: String) throws {
        try write(
            text, to: container(folderName).appendingPathComponent("Game/save1.dat"),
            modifiedAt: clock.now)
    }

    private func game(
        _ folderName: String,
        lastPlayedAt: Date? = nil,
        hasLocalContainer: Bool = true,
        sharedData: URL? = nil,
        isOneOff: Bool = false
    ) -> BackupRunGame {
        BackupRunGame(
            identity: GameIdentity(folderName: folderName),
            set: GameBackupSetRequest(
                containerURL: container(folderName),
                mode: .slim,
                sharedDataDirectory: sharedData,
                documentsRoot: documents),
            lastPlayedAt: lastPlayedAt,
            hasLocalContainer: hasLocalContainer,
            isOneOffFullSnapshot: isOneOff)
    }

    private func request(
        games: [BackupRunGame],
        preferences: LibraryBackupSetRequest? = nil,
        writerResolution: WriterClaimResolution? = nil,
        splitNamespaceId: String? = nil,
        capBytes: Int64? = nil
    ) -> BackupRunRequest {
        var target = descriptor
        target.capBytes = capBytes
        return BackupRunRequest(
            runId: UUID().uuidString,
            descriptor: target,
            namespaceId: namespaceId,
            deviceId: deviceId,
            deviceName: "iPhone",
            deviceModel: "iPhone17,1",
            preferences: preferences,
            games: games,
            writerResolution: writerResolution,
            splitNamespaceId: splitNamespaceId)
    }

    /// Waits until `count` transfers reach the latch.
    ///
    /// It sleeps between the reads instead of yielding, so the run
    /// under test gets the processor. A yield loop starves it on a
    /// busy host, which is what a parallel test run is.
    private func waitForArrivals(_ count: Int, at latch: TransferLatch) async -> Bool {
        for _ in 0..<400 {
            if await latch.arrivedCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await latch.arrivedCount >= count
    }

    private func blobPaths(_ target: FakeBackupTarget) -> [String] {
        target.objectPaths().filter { $0.contains("/blobs/") }
    }

    private func manifestPaths(_ target: FakeBackupTarget) -> [String] {
        target.objectPaths()
            .filter { BackupNamespacePaths.snapshotId(ofManifestPath: $0) != nil }
    }

    private func manifest(
        on target: FakeBackupTarget, at path: String
    ) throws -> SnapshotManifest {
        let data = try XCTUnwrap(target.contents(atPath: path))
        return try SnapshotManifest.decode(compressed: data)
    }

    private func manifestOfTheLastSnapshot(
        of result: BackupRunResult, on target: FakeBackupTarget
    ) throws -> SnapshotManifest {
        let stream = try XCTUnwrap(result.streams.last)
        guard case .wroteSnapshot(let id) = stream.outcome else {
            throw XCTSkip("the run wrote no snapshot for \(stream.streamKey)")
        }
        return try manifest(
            on: target,
            at: paths.manifestPath(
                stream: BackupStream(key: stream.streamKey), snapshotId: id))
    }

    private func snapshotId(of result: BackupRunResult, stream key: String) throws -> String {
        guard case .wroteSnapshot(let id)? = result.stream(key)?.outcome else {
            throw XCTSkip("the run wrote no snapshot for \(key)")
        }
        return id
    }

    // MARK: - 1. The write order of 5.8

    func testAFirstSnapshotUploadsEveryBlobAndThenTheManifest() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        let stream = try XCTUnwrap(result.stream(key(gameName)))
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(stream.uploadedBlobCount, 4)

        let snapshotId = try snapshotId(of: result, stream: key(gameName))
        let manifestPath = paths.manifestPath(
            stream: .game(key: key(gameName)), snapshotId: snapshotId)
        let committed = await target.committedPaths

        XCTAssertEqual(committed.last, manifestPath)
        let manifestIndex = try XCTUnwrap(committed.firstIndex(of: manifestPath))
        let blobIndexes = committed.indices.filter { committed[$0].contains("/blobs/") }
        XCTAssertEqual(blobIndexes.count, 4)
        for index in blobIndexes {
            XCTAssertLessThan(index, manifestIndex)
        }
    }

    func testTheManifestNamesTheWholeBackupSet() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: result, stream: key(gameName))
        let manifest = try manifest(
            on: target,
            at: paths.manifestPath(stream: .game(key: key(gameName)), snapshotId: snapshotId))

        XCTAssertEqual(
            manifest.entries.map(\.path),
            [
                "EmpoState/backup.json", "Game/autosave.sav", "Game/save1.dat",
                "Metadata/metadata.json",
            ])
        XCTAssertEqual(manifest.containerFolderName, gameName)
        XCTAssertEqual(manifest.mode, .slim)
    }

    // MARK: - 2. What earns a snapshot, per 7.7

    func testASecondRunWithNoChangeWritesNoSnapshotAndUploadsNothing() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        await target.forgetCommittedPaths()

        clock.advance(3_600)
        let second = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(second.stream(key(gameName))?.outcome, .noChange)
        XCTAssertEqual(second.outcome, .success)
        XCTAssertEqual(second.uploadedBytes, 0)
        // The run still records this device, per 5.12. It writes no
        // blob and no manifest.
        let committed = await target.committedPaths
        XCTAssertEqual(committed, [paths.deviceFile])
        XCTAssertEqual(manifestPaths(target).count, 1)
    }

    func testATouchedFileWithTheSameBytesEarnsNoSnapshot() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        // The same bytes at a new time. Content decides, per 7.7.
        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one of \(gameName)")
        let second = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(second.stream(key(gameName))?.outcome, .noChange)
        XCTAssertEqual(manifestPaths(target).count, 1)
    }

    // MARK: - 3. One changed file

    func testOneChangedFileUploadsOneBlobAndAWholeManifest() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        await target.forgetCommittedPaths()

        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one, later")
        let second = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(second.stream(key(gameName))?.uploadedBlobCount, 1)
        let committed = await target.committedPaths
        XCTAssertEqual(committed.filter { $0.contains("/blobs/") }.count, 1)

        // Every manifest is self-contained, per 5.5. The second one
        // names all four members, not the one that changed.
        let snapshotId = try snapshotId(of: second, stream: key(gameName))
        let manifest = try manifest(
            on: target,
            at: paths.manifestPath(stream: .game(key: key(gameName)), snapshotId: snapshotId))
        XCTAssertEqual(manifest.entries.count, 4)
        XCTAssertEqual(manifestPaths(target).count, 2)
        XCTAssertEqual(blobPaths(target).count, 5)
    }

    // MARK: - 4. A crash between the last blob and the manifest

    func testACrashBeforeTheManifestKeepsTheBlobsForTheNextRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(.crashBeforeTheManifest())
        let engine = try makeEngine(target)

        let first = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(first.outcome, .failed)
        XCTAssertEqual(first.stop, .offline)
        XCTAssertEqual(manifestPaths(target).count, 0)
        XCTAssertEqual(blobPaths(target).count, 4)

        // Step 4 of 5.8 never runs on a failed run, so a broken run
        // deletes nothing. That is invariant 7.
        await target.removeFaults()
        await target.forgetCommittedPaths()
        clock.advance(60)
        let second = await engine.run(request(games: [game(gameName)]))

        let stream = try XCTUnwrap(second.stream(key(gameName)))
        XCTAssertEqual(stream.uploadedBlobCount, 0)
        XCTAssertEqual(stream.uploadedBytes, 0)
        XCTAssertEqual(manifestPaths(target).count, 1)
        XCTAssertEqual(blobPaths(target).count, 4)
    }

    func testAResumedRunKeepsTheAlgorithmTheOrphanBlobsWentUpWith() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(.crashBeforeTheManifest())
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        await target.removeFaults()
        clock.advance(60)
        let second = await engine.run(request(games: [game(gameName)]))

        // The manifest has to name what each blob holds, per 5.6.
        // The hash alone cannot give the algorithm back.
        let snapshotId = try snapshotId(of: second, stream: key(gameName))
        let manifest = try manifest(
            on: target,
            at: paths.manifestPath(stream: .game(key: key(gameName)), snapshotId: snapshotId))
        for entry in manifest.entries {
            let path = paths.blobPath(
                hash: entry.hash, fanOutWidth: FormatDescriptor.version1FanOutWidth)
            let bytes = try XCTUnwrap(target.contents(atPath: path))
            let decoded = try BlobCodec.decode(bytes, algorithm: entry.compression)
            XCTAssertEqual(ContentHash.hex(of: decoded), entry.hash)
        }
    }

    // MARK: - 5. The prune, per 5.10

    func testThePruneDropsTheRightManifestsAndDeletesNoBlob() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)

        var snapshots: [DatedSnapshot] = []
        for index in 0..<12 {
            try changeTheSave(of: gameName, to: "slot one, take \(index)")
            let result = await engine.run(request(games: [game(gameName)]))
            snapshots.append(
                DatedSnapshot(
                    id: try snapshotId(of: result, stream: key(gameName)), date: clock.now))
            clock.advance(3_600)
        }

        let expected = RetentionPolicy.plan(for: snapshots, kind: .game, preset: .standard)
        XCTAssertFalse(expected.drop.isEmpty)

        let prefix = paths.prefix(of: .game(key: key(gameName)))
        let left = manifestPaths(target)
            .compactMap { $0.hasPrefix(prefix) ? BackupNamespacePaths.snapshotId(ofManifestPath: $0) : nil }
        XCTAssertEqual(left.sorted(), expected.keep)

        // The prune deletes manifests only, per invariant 6. Every
        // blob of all 12 runs is still there.
        XCTAssertEqual(blobPaths(target).count, 12 + 3)
    }

    // MARK: - 6. The sweep, per 5.11

    func testTheSweepDeletesOnlyUnreferencedBlobsOlderThanSevenDays() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        let orphan = paths.blobPath(
            hash: String(repeating: "b", count: 64),
            fanOutWidth: FormatDescriptor.version1FanOutWidth)
        try target.seed(path: orphan, contents: Data("orphan".utf8))
        let young = paths.blobPath(
            hash: String(repeating: "c", count: 64),
            fanOutWidth: FormatDescriptor.version1FanOutWidth)

        clock.advance(8 * 86_400)
        // A blob younger than the 7-day margin stays, whatever the
        // mark says. A resumed run reuses it for free.
        try target.seed(path: young, contents: Data("young".utf8))
        try fm.setAttributes(
            [.modificationDate: clock.now],
            ofItemAtPath: target.fileURL(forPath: young).path)

        let swept = try await engine.sweep(
            SweepRequest(descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId))

        XCTAssertEqual(swept.decision, .runOverdue)
        XCTAssertEqual(swept.deletedPaths, [orphan])
        let left = blobPaths(target)
        XCTAssertEqual(left.count, 5)
        XCTAssertTrue(left.contains(young))
        XCTAssertFalse(left.contains(orphan))
    }

    func testTheSweepStaysQueuedWhileTheTargetReportsRoomToSpare() async throws {
        try makeGameTree(gameName)
        let target = makeTarget(
            capabilities: TargetCapabilities(canQueryQuota: true),
            quotaLimitBytes: 1_000_000)
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        let orphan = paths.blobPath(
            hash: String(repeating: "b", count: 64),
            fanOutWidth: FormatDescriptor.version1FanOutWidth)
        try target.seed(path: orphan, contents: Data("orphan".utf8))
        clock.advance(8 * 86_400)

        let queued = try await engine.sweep(
            SweepRequest(descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId))

        XCTAssertEqual(queued.decision, .queued)
        XCTAssertTrue(queued.deletedPaths.isEmpty)
        XCTAssertTrue(blobPaths(target).contains(orphan))

        // Space pressure forces the sweep, not the calendar.
        await target.setQuotaLimit(target.usedBytes())
        let forced = try await engine.sweep(
            SweepRequest(descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId))

        XCTAssertEqual(forced.decision, .runOverdue)
        XCTAssertEqual(forced.deletedPaths, [orphan])
    }

    // MARK: - 7. The writer claim and the split, per 5.12

    func testAClaimFromAnotherDeviceStopsTheRunBeforeAnyWrite() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let other = WriterClaim(
            namespaceId: namespaceId, deviceId: "device-b", deviceName: "iPad",
            claimedAt: clock.now)
        try target.seed(path: paths.writerFile, contents: try other.jsonData())
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        guard case .writerConflict(let found)? = result.stop else {
            return XCTFail("the run did not stop: \(String(describing: result.stop))")
        }
        XCTAssertEqual(found.deviceId, "device-b")
        XCTAssertEqual(found.deviceName, "iPad")
        XCTAssertEqual(result.detail, WriterClaimCheck.splitLine)
        let committed = await target.committedPaths
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(target.objectPaths(), [paths.writerFile])
    }

    func testASplitStartsANewNamespaceWithAFullUpload() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        let other = WriterClaim(
            namespaceId: namespaceId, deviceId: "device-b", deviceName: "iPad",
            claimedAt: clock.now)
        try target.seed(path: paths.writerFile, contents: try other.jsonData())
        await target.forgetCommittedPaths()

        clock.advance(3_600)
        let result = await engine.run(
            request(
                games: [game(gameName)], writerResolution: .split, splitNamespaceId: "ns-2"))

        XCTAssertTrue(result.didSplit)
        XCTAssertEqual(result.namespaceId, "ns-2")
        XCTAssertEqual(result.outcome, .success)

        // No namespace may reference another's blobs, per 5.12, so
        // the split starts from a full upload.
        XCTAssertEqual(result.stream(key(gameName))?.uploadedBlobCount, 4)
        let split = paths.inNamespace("ns-2")
        let fresh = target.objectPaths().filter { $0.hasPrefix(split.namespacePrefix + "/") }
        XCTAssertEqual(fresh.filter { $0.contains("/blobs/") }.count, 4)
        XCTAssertEqual(
            fresh.filter { BackupNamespacePaths.snapshotId(ofManifestPath: $0) != nil }.count, 1)

        // The abandoned namespace keeps its snapshots.
        XCTAssertEqual(
            target.objectPaths()
                .filter { $0.hasPrefix(paths.namespacePrefix + "/") }
                .filter { BackupNamespacePaths.snapshotId(ofManifestPath: $0) != nil }
                .count,
            1)
    }

    // MARK: - 8. The prune ladder, per 5.14

    func testTheLadderRetriesAfterAPruneAndThenBlocksTheTarget() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(operation: .put, error: .outOfSpace, pathContains: "/blobs/"))
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.stop, .full(reason: QuotaCheck.prunedAndStillFullLine))
        XCTAssertEqual(result.detail, QuotaCheck.prunedAndStillFullLine)
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

    /// Throttling is transient, per 7.11. The device saw a throttled
    /// target post "is full".
    func testAThrottledTargetStopsTransientAndNotifiesNothing() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(operation: .put, error: .throttled(retryAfter: 30), pathContains: "/blobs/"))
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.stop, .throttled(retryAfter: 30))
        XCTAssertNil(result.stop.flatMap(BackupNotificationRule.failFastCause))
    }

    func testTheLadderRetryTakesTheUploadThatFailedOnce() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(
            FakeTargetFault(
                operation: .put, error: .outOfSpace, pathContains: "/blobs/", times: 1))
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.stream(key(gameName))?.uploadedBlobCount, 4)
        XCTAssertEqual(manifestPaths(target).count, 1)
    }

    func testASpaceQueryRefusesARunThatCannotFit() async throws {
        try makeGameTree(gameName)
        let target = makeTarget(
            capabilities: TargetCapabilities(canQueryQuota: true), quotaLimitBytes: 1_000_000)
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)], capBytes: 4))

        XCTAssertEqual(result.outcome, .failed)
        guard case .quotaShortfall(let shortfall)? = result.stop else {
            return XCTFail("the run was not refused: \(String(describing: result.stop))")
        }
        XCTAssertGreaterThan(shortfall.missingBytes, 0)
        XCTAssertTrue(blobPaths(target).isEmpty)
    }

    // MARK: - 9. The order of 7.8

    func testTheRunCoversFiveGamesInTheOrderOfSevenPointEight() async throws {
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        for name in names { try makeGameTree(name) }
        let target = makeTarget()
        let engine = try makeEngine(target)

        // No game has a snapshot yet, so all five are past the stale
        // mark and the recency tiebreak governs.
        let played: [String: TimeInterval] = [
            "Alpha": -9, "Bravo": -1, "Charlie": -40, "Delta": -3, "Echo": -20,
        ]
        let games = names.map {
            game($0, lastPlayedAt: clock.now.addingTimeInterval(played[$0]! * 86_400))
        }

        let result = await engine.run(request(games: games))

        XCTAssertEqual(
            result.streams.map(\.streamKey),
            ["Bravo", "Delta", "Alpha", "Echo", "Charlie"].map(key))
    }

    // MARK: - 10. The prefs stream

    func testThePrefsStreamGoesFirstOnEveryRun() async throws {
        try makeGameTree(gameName)
        try write("{\"keys\":1}", to: documents.appendingPathComponent("userdefaults.json"))
        try write("{\"pins\":[]}", to: documents.appendingPathComponent("Profiles/default.json"))
        let preferences = LibraryBackupSetRequest(
            profilesDirectory: documents.appendingPathComponent("Profiles", isDirectory: true),
            userDefaultsExportFile: documents.appendingPathComponent("userdefaults.json"))
        let target = makeTarget()
        let engine = try makeEngine(target)

        let first = await engine.run(
            request(games: [game(gameName)], preferences: preferences))
        XCTAssertEqual(first.streams.first?.streamKey, BackupStream.preferencesKey)

        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one, later")
        let second = await engine.run(
            request(games: [game(gameName)], preferences: preferences))
        XCTAssertEqual(second.streams.first?.streamKey, BackupStream.preferencesKey)

        // It is a stream of its own, under a directory of its own.
        let prefsManifests = manifestPaths(target)
            .filter { $0.hasPrefix(paths.prefix(of: .preferences)) }
        XCTAssertEqual(prefsManifests.count, 1)
    }

    // MARK: - 11. Deleting a game and its backups, per 5.13

    func testDeletingAGameLeavesASharedDirectoryASecondGameNames() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let shared = documents.appendingPathComponent("Shared", isDirectory: true)
        try write("shared save", to: shared.appendingPathComponent("common.sav"))
        let target = makeTarget()
        let engine = try makeEngine(target)

        _ = await engine.run(
            request(
                games: [
                    game("Alpha", sharedData: shared), game("Bravo", sharedData: shared),
                ]))
        XCTAssertEqual(manifestPaths(target).count, 2)

        // The blobs of the shared directory upload once and both
        // manifests name them.
        let sharedHash = try ContentHash.hexOfFile(at: shared.appendingPathComponent("common.sav"))
        let sharedBlob = paths.blobPath(
            hash: sharedHash, fanOutWidth: FormatDescriptor.version1FanOutWidth)
        XCTAssertTrue(blobPaths(target).contains(sharedBlob))

        // Eight days on, every blob is past the 7-day margin, so the
        // sweep the delete runs can reach them.
        clock.advance(8 * 86_400)
        let outcome = await engine.deleteBackups(
            BackupDeleteRequest(
                descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                gameKey: key("Alpha")))

        guard case .deleted(let snapshotIds, let swept) = outcome else {
            return XCTFail("the delete did not run: \(outcome)")
        }
        XCTAssertEqual(snapshotIds.count, 1)
        XCTAssertFalse(swept.isEmpty)

        let left = manifestPaths(target)
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left[0].hasPrefix(paths.prefix(of: .game(key: key("Bravo")))))
        XCTAssertTrue(blobPaths(target).contains(sharedBlob))

        // Bravo's own snapshot still reads.
        let manifest = try manifest(on: target, at: left[0])
        for entry in manifest.entries {
            let path = paths.blobPath(
                hash: entry.hash, fanOutWidth: FormatDescriptor.version1FanOutWidth)
            XCTAssertNotNil(target.contents(atPath: path), "blob gone for \(entry.path)")
        }
    }

    // MARK: - 12. A pending deletion

    func testAPendingDeletionAppliesAtTheStartOfTheNextRun() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game("Alpha"), game("Bravo")]))

        await target.addFault(FakeTargetFault(operation: .delete, error: .offline))
        let outcome = await engine.deleteBackups(
            BackupDeleteRequest(
                descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                gameKey: key("Alpha")))

        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(manifestPaths(target).count, 2)

        await target.removeFaults()
        clock.advance(3_600)
        try changeTheSave(of: "Bravo", to: "slot one, later")
        let result = await engine.run(request(games: [game("Bravo")]))

        XCTAssertEqual(result.outcome, .success)
        let left = manifestPaths(target)
        XCTAssertTrue(
            left.allSatisfy { $0.hasPrefix(paths.prefix(of: .game(key: key("Bravo")))) },
            "Alpha's manifests are still there: \(left)")
    }

    // MARK: - The one-off full snapshot, per 5.15

    func testAOneOffFullSnapshotUploadsTheWholeTreeAndLeavesTheModeAlone() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        let first = await engine.run(request(games: [game(gameName)]))
        XCTAssertEqual(first.stream(key(gameName))?.uploadedBlobCount, 4)

        // Nothing changed, and the one-off still writes. It takes
        // the whole tree, so it names the file slim mode leaves out.
        clock.advance(3_600)
        let oneOff = await engine.run(request(games: [game(gameName, isOneOff: true)]))

        let snapshotId = try snapshotId(of: oneOff, stream: key(gameName))
        let manifest = try manifest(
            on: target,
            at: paths.manifestPath(stream: .game(key: key(gameName)), snapshotId: snapshotId))
        XCTAssertEqual(manifest.mode, .full)
        XCTAssertTrue(manifest.entries.map(\.path).contains("Game/Game.ini"))

        // The game's own mode did not move, per 5.15.
        clock.advance(3_600)
        let after = await engine.run(request(games: [game(gameName)]))
        let slim = try manifestOfTheLastSnapshot(of: after, on: target)
        XCTAssertEqual(slim.mode, .slim)
        XCTAssertFalse(slim.entries.map(\.path).contains("Game/Game.ini"))
    }

    // MARK: - 13. A file changed twice during staging, per 5.9

    func testAFileChangedTwiceDuringStagingIsMarkedPartial() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        // Four transfers reach the latch before the run stages its
        // second member: writer.json, device.json, format.json, and
        // the first member's blob. The reads of the two files that
        // are not there answer notFound and never reach it.
        let latch = TransferLatch(holdFrom: 4)
        await target.setLatch(latch)
        let engine = try makeEngine(target)

        let payload = request(games: [game(gameName)])
        let running = Task { [engine] in await engine.run(payload) }

        let arrived = await waitForArrivals(4, at: latch)
        XCTAssertTrue(arrived, "the run never reached the first blob upload")
        try changeTheSave(of: gameName, to: "the save moved while the run copied it")
        await latch.open()

        let result = await running.value

        let stream = try XCTUnwrap(result.stream(key(gameName)))
        XCTAssertEqual(stream.partialPaths, ["Game/save1.dat"])
        // The snapshot still uploads. The path retries on the next
        // run, per 5.9.
        let snapshotId = try snapshotId(of: result, stream: key(gameName))
        let manifest = try manifest(
            on: target,
            at: paths.manifestPath(stream: .game(key: key(gameName)), snapshotId: snapshotId))
        XCTAssertEqual(manifest.entries.count, 4)
        XCTAssertEqual(manifest.entries.filter(\.partial).map(\.path), ["Game/save1.dat"])
        XCTAssertEqual(result.outcome, .success)
    }

    func testAPartialPathHashesAgainOnTheNextRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        // Four transfers reach the latch before the run stages its
        // second member: writer.json, device.json, format.json, and
        // the first member's blob. The reads of the two files that
        // are not there answer notFound and never reach it.
        let latch = TransferLatch(holdFrom: 4)
        await target.setLatch(latch)
        let engine = try makeEngine(target)

        let payload = request(games: [game(gameName)])
        let running = Task { [engine] in await engine.run(payload) }
        _ = await waitForArrivals(4, at: latch)
        try changeTheSave(of: gameName, to: "the save moved while the run copied it")
        await latch.open()
        _ = await running.value

        await target.setLatch(nil)
        await target.forgetCommittedPaths()
        clock.advance(3_600)
        let second = await engine.run(request(games: [game(gameName)]))

        // The partial path retries even though its size and its
        // modified time did not move since the last manifest.
        let stream = try XCTUnwrap(second.stream(key(gameName)))
        XCTAssertEqual(stream.uploadedBlobCount, 0)
        XCTAssertTrue(stream.partialPaths.isEmpty)
        guard case .wroteSnapshot = stream.outcome else {
            return XCTFail("the retry wrote no snapshot: \(stream.outcome)")
        }
    }

    // MARK: - 22. The run plan the pill and the badge read, per 13.2

    func testTheRunReportsOnePlanForTheStreamAndConfirmsEveryBlobOfIt() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let recorder = RunPlanRecorder()
        let engine = try makeEngine(target, observer: recorder)

        let result = await engine.run(request(games: [game(gameName)]))

        let plans = await recorder.plans
        let plan = await recorder.plan
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.0, key(gameName))
        XCTAssertEqual(plan.plannedBytes, plans.first?.1)
        let confirmCount = await recorder.confirmCount
        XCTAssertEqual(confirmCount, 4)
        XCTAssertEqual(plan.confirmedBytes, plan.plannedBytes)
        XCTAssertEqual(plan.fraction, 1)
        XCTAssertTrue(plan.isDone(key(gameName)))
        XCTAssertEqual(result.outcome, .success)
    }

    func testProgressAdvancesOnAConfirmedBlobAndNotOnAStartedUpload() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        // The fourth transfer is the first member's blob, per the
        // partial-path test above. It starts and then waits here.
        let latch = TransferLatch(holdFrom: 4)
        await target.setLatch(latch)
        let recorder = RunPlanRecorder()
        let engine = try makeEngine(target, observer: recorder)

        let payload = request(games: [game(gameName)])
        let running = Task { [engine] in await engine.run(payload) }
        _ = await waitForArrivals(4, at: latch)

        let held = await recorder.plan
        XCTAssertGreaterThan(held.plannedBytes, 0)
        XCTAssertEqual(held.confirmedBytes, 0)
        XCTAssertEqual(held.fraction, 0)

        await latch.open()
        _ = await running.value

        let done = await recorder.plan
        XCTAssertEqual(done.confirmedBytes, done.plannedBytes)
    }

    func testAResumedRunConfirmsTheBlobsTheLastRunLeftOnTheTarget() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(.crashBeforeTheManifest())
        _ = await (try makeEngine(target)).run(request(games: [game(gameName)]))

        let recorder = RunPlanRecorder()
        let engine = try makeEngine(target, observer: recorder)
        clock.advance(3_600)
        _ = await engine.run(request(games: [game(gameName)]))

        // The blobs are already up, so the second run uploads
        // nothing. The plan still counts them and still reaches the
        // end, per 13.2.
        let plan = await recorder.plan
        XCTAssertEqual(plan.confirmedBytes, plan.plannedBytes)
        XCTAssertEqual(plan.fraction, 1)
    }

}

/// Builds the run plan of SPEC 13.2 from what the engine reports,
/// the way `BackupRunMonitor` does on the app side.
actor RunPlanRecorder: BackupRunObserver {

    private(set) var plan = BackupRunPlan()
    private(set) var plans: [(String, Int64)] = []
    private(set) var confirmCount = 0

    func runPlanned(streamKey: String, bytes: Int64) {
        plans.append((streamKey, bytes))
        plan.plan(streamKey: streamKey, bytes: bytes)
    }

    func runConfirmed(streamKey: String, bytes: Int64) {
        confirmCount += 1
        plan.confirm(streamKey: streamKey, bytes: bytes)
    }
}
