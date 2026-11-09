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
        // The store keeps a date as seconds since 1970, and a date
        // with a fraction can come back one bit off.
        clock = TestClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))
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
        _ target: FakeBackupTarget, observer: (any BackupRunObserver)? = nil,
        stateURL: URL? = nil
    ) throws -> SnapshotEngine {
        let store = try BackupStateStore(url: stateURL)
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
        trigger: BackupTrigger = .manual,
        preferences: LibraryBackupSetRequest? = nil,
        writerAnswer: WriterConflicts.Answer? = nil,
        capBytes: Int64? = nil
    ) -> BackupRunRequest {
        var target = descriptor
        target.capBytes = capBytes
        return BackupRunRequest(
            runId: UUID().uuidString,
            trigger: trigger,
            descriptor: target,
            namespaceId: namespaceId,
            deviceId: deviceId,
            deviceName: "iPhone",
            deviceModel: "iPhone17,1",
            preferences: preferences,
            games: games,
            writerAnswer: writerAnswer)
    }

    /// Waits until `count` transfers reach the latch.
    ///
    /// It sleeps between the reads instead of yielding, so the run
    /// under test gets the processor. A yield loop starves it on a
    /// busy host, which is what a parallel test run is.
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
            XCTFail("the run wrote no snapshot for \(stream.streamKey)")
            throw NoSnapshot()
        }
        return try manifest(
            on: target,
            at: paths.manifestPath(
                stream: BackupStream(key: stream.streamKey), snapshotId: id))
    }

    private func snapshotId(of result: BackupRunResult, stream key: String) throws -> String {
        guard case .wroteSnapshot(let id)? = result.stream(key)?.outcome else {
            XCTFail("the run wrote no snapshot for \(key)")
            throw NoSnapshot()
        }
        return id
    }

    // MARK: - 1. The write order of 5.8

    func testAStateWriteThatFailsReachesTheNote() async throws {
        try makeGameTree(gameName)
        let store = try BackupStateStore(url: nil)
        // The state database is a cache. A run whose inserts and
        // updates fail still reaches the target, and every failure
        // reaches the note. A namespace clear that fails stops the
        // run, so deletes still work.
        for row in try store.database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        {
            guard let table = row[0].string else { continue }
            for event in ["INSERT", "UPDATE"] {
                try store.database.run(
                    "CREATE TRIGGER no_\(event)_\(table) BEFORE \(event) ON \(table) BEGIN SELECT RAISE(ABORT, 'held'); END"
                )
            }
        }
        let notes = NoteRecorder()
        let clock = self.clock!
        let engine = SnapshotEngine(
            provider: makeTarget(),
            store: store,
            localRoot: localRoot,
            clock: FakeBackupClock(),
            now: { clock.now },
            note: { notes.add($0) })

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .success)
        XCTAssertFalse(notes.lines.isEmpty)
        XCTAssertTrue(notes.lines.contains { $0.contains("the checkpoint of") })
        XCTAssertTrue(notes.lines.contains { $0.contains("the interrupted-run record of") })
        XCTAssertTrue(notes.lines.contains { $0.contains("the run history row of") })
    }

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

    func testAWriteTheServiceRefusesNamesTheFixForThatService() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .list, error: .permissionDenied))
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(
            result.stop, .blocked(reason: BackupProviderError.permissionDenied.line(for: .webdav)))
    }

    func testAServerThatIsDownStopsTheRunBeforeATransferWaitsForIt() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(FakeTargetFault(operation: .list, error: .offline))
        let latch = TransferLatch()
        await target.setLatch(latch)
        let engine = try makeEngine(target)
        let request = request(games: [game(gameName)])

        let running = Task { [engine] in await engine.run(request) }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            await latch.open()
            return true
        }
        let result = await running.value
        timeout.cancel()

        let waited = (try? await timeout.value) ?? false
        XCTAssertFalse(waited, "a transfer waited for the server")
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.stop, .offline)
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

    func testABlobTheTargetHasNotConfirmedStaysOutOfTheCheckpoint() async throws {
        try makeGameTree(gameName)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let target = FakeBackupTarget(
            directory: targetDirectory, confirmsLater: true, clock: FakeBackupClock())
        let engine = try makeEngine(target, stateURL: stateURL)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.stream(key(gameName))?.outcome, .blobsOnly)
        XCTAssertEqual(result.stream(key(gameName))?.uploadedBlobCount, 4)
        XCTAssertEqual(manifestPaths(target).count, 0)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        let checkpoint = try store.checkpoint(targetId: targetId, gameKey: key(gameName))
        XCTAssertEqual(checkpoint?.confirmedBlobs ?? [], [])
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

    func testAJoinFromAnEarlierLaunchStaysInTheNextSnapshot() async throws {
        let root = try makeGameTree(gameName)
        try write("level 3", to: root.appendingPathComponent("Game/Data/progress.bin"))
        let target = makeTarget()
        let engine = try makeEngine(target)
        var joined = game(gameName)
        joined.set.runtimeWatchPaths = ["Game/Data/progress.bin"]
        _ = await engine.run(request(games: [joined]))

        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one, after a relaunch")
        let next = await engine.run(request(games: [game(gameName)]))

        let entry = try manifestOfTheLastSnapshot(of: next, on: target).entries
            .first { $0.path == "Game/Data/progress.bin" }
        XCTAssertEqual(entry?.detectionSource, .runtimeWatch)
    }

    private func assertARunWithNoChangeCountsAsASuccess(
        touch: (URL) throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let root = try makeGameTree(gameName)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let engine = try makeEngine(makeTarget(), stateURL: stateURL)
        _ = await engine.run(request(games: [game(gameName)]))

        clock.advance(3 * 86_400)
        try touch(root)
        let player = try BackupStateStore(url: stateURL)
        try player.markDirty(gameKey: key(gameName), targetIds: [targetId], at: clock.now)
        player.close()
        let scannedAt = clock.now
        let next = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(next.stream(key(gameName))?.outcome, .noChange, file: file, line: line)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        let staleness = try store.staleness(targetId: targetId, gameKey: key(gameName))
        let lastSuccessAt = try XCTUnwrap(staleness?.lastSuccessAt, file: file, line: line)
        XCTAssertEqual(
            lastSuccessAt.timeIntervalSince1970, scannedAt.timeIntervalSince1970, accuracy: 0.001,
            file: file, line: line)
        XCTAssertEqual(try store.dirtyGames(), [], file: file, line: line)
    }

    func testOneTargetThatFinishesKeepsTheMarkOfTheOtherTarget() async throws {
        try makeGameTree(gameName)
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let player = try BackupStateStore(url: stateURL)
        try player.markDirty(gameKey: key(gameName), targetIds: [targetId, "target-2"], at: clock.now)
        player.close()
        let engine = try makeEngine(makeTarget(), stateURL: stateURL)

        let result = await engine.run(request(games: [game(gameName)]))

        guard case .wroteSnapshot? = result.stream(key(gameName))?.outcome else {
            return XCTFail("the run wrote no snapshot")
        }
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        XCTAssertEqual(try store.dirtyGames().map(\.targetId), ["target-2"])
    }

    func testAClosedStreamLeavesNoInterruptedRunRecordThatNamesIt() async throws {
        let other = "Second Quest"
        try makeGameTree(gameName)
        try makeGameTree(other)
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let watcher = StoreWatcher(stateURL: stateURL)
        let engine = try makeEngine(makeTarget(), observer: watcher, stateURL: stateURL)

        _ = await engine.run(request(games: [game(gameName), game(other)]))

        let seen = await watcher.seen
        let games = [key(gameName), key(other)]
        let uploads = seen.filter { $0.event == "uploads" && games.contains($0.stream) }
        XCTAssertEqual(uploads.count, 2)
        let firstStream = try XCTUnwrap(uploads.first?.stream)
        XCTAssertTrue(
            seen.contains { $0.event == "confirmed" && $0.record == firstStream },
            "the first stream wrote no record")
        XCTAssertNil(uploads.last?.record)
    }

    func testTheRunRowHasNoEndUntilTheRunEnds() async throws {
        try makeGameTree(gameName)
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let watcher = StoreWatcher(stateURL: stateURL)
        let engine = try makeEngine(makeTarget(), observer: watcher, stateURL: stateURL)

        _ = await engine.run(request(games: [game(gameName)]))

        let midRun = await watcher.runRowEnds
        XCTAssertFalse(midRun.isEmpty)
        XCTAssertEqual(midRun, midRun.map { _ in nil })
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        XCTAssertEqual(try store.runHistory().first?.end?.outcome, .success)
    }

    func testARunThatFindsNothingNewCountsAsASuccess() async throws {
        try await assertARunWithNoChangeCountsAsASuccess { _ in }
    }

    func testARunThatReadsTheSameBytesAgainCountsAsASuccess() async throws {
        try await assertARunWithNoChangeCountsAsASuccess { root in
            try fm.setAttributes(
                [.modificationDate: clock.now],
                ofItemAtPath: root.appendingPathComponent("Game/save1.dat").path)
        }
    }

    func testANightlyRunEndsWithTheSweepThatIsDue() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        let orphan = paths.blobPath(
            hash: String(repeating: "b", count: 64),
            fanOutWidth: FormatDescriptor.version1FanOutWidth)
        try target.seed(path: orphan, contents: Data("orphan".utf8))
        clock.advance(8 * 86_400)

        _ = await engine.run(request(games: [game(gameName)], trigger: .sessionEndOrBackground))
        XCTAssertTrue(blobPaths(target).contains(orphan))

        let nightly = await engine.run(request(games: [game(gameName)], trigger: .nightly))

        XCTAssertEqual(nightly.outcome, .success)
        XCTAssertFalse(blobPaths(target).contains(orphan))
        XCTAssertEqual(blobPaths(target).count, 4)
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

    private func sweepNow(_ engine: SnapshotEngine) async throws {
        _ = try await engine.sweep(
            SweepRequest(
                descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                force: true))
    }

    private func assertEveryBlobOfTheLastSnapshotIsThere(
        _ result: BackupRunResult, on target: FakeBackupTarget,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let manifest = try manifestOfTheLastSnapshot(of: result, on: target)
        for entry in manifest.entries {
            let path = paths.blobPath(
                hash: entry.hash, fanOutWidth: FormatDescriptor.version1FanOutWidth)
            XCTAssertNotNil(
                target.contents(atPath: path), "no blob for \(entry.path)", file: file, line: line)
        }
    }

    func testASaveThatGoesBackToSweptBytesUploadsItsBlobAgain() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        let first = await engine.run(request(games: [game(gameName)]))
        let firstManifest = paths.manifestPath(
            stream: .game(key: key(gameName)),
            snapshotId: try snapshotId(of: first, stream: key(gameName)))

        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one, later")
        _ = await engine.run(request(games: [game(gameName)]))
        try await target.delete(paths: [firstManifest])
        clock.advance(8 * 86_400)
        try await sweepNow(engine)

        try changeTheSave(of: gameName, to: "slot one of \(gameName)")
        let third = await engine.run(request(games: [game(gameName)]))

        try assertEveryBlobOfTheLastSnapshotIsThere(third, on: target)
    }

    func testAResumedRunAfterASweepNamesNoMissingBlob() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        await target.addFault(.crashBeforeTheManifest())
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        await target.removeFaults()

        clock.advance(8 * 86_400)
        try await sweepNow(engine)
        let resumed = await engine.run(request(games: [game(gameName)]))

        try assertEveryBlobOfTheLastSnapshotIsThere(resumed, on: target)
    }

    func testTheSweepDeletesNothingWhenAManifestCannotBeRead() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        let manifestPath = try XCTUnwrap(manifestPaths(target).first)
        try target.seed(path: manifestPath, contents: Data("not a manifest".utf8))
        clock.advance(8 * 86_400)

        do {
            _ = try await engine.sweep(
                SweepRequest(
                    descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                    force: true))
            XCTFail("the sweep ran past a manifest it could not read")
        } catch {}

        XCTAssertEqual(blobPaths(target).count, 4)
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
        XCTAssertEqual(result.detail, BackupNotificationRule.writerSplitLine)
        let committed = await target.committedPaths
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(target.objectPaths(), [paths.writerFile])
    }

    func testAClaimThatCannotBeReadStopsTheRunBeforeAnyWrite() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let damaged = Data("{\"version\":".utf8)
        try target.seed(path: paths.writerFile, contents: damaged)
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)]))

        guard case .writerConflict? = result.stop else {
            return XCTFail("the run did not stop: \(String(describing: result.stop))")
        }
        let committed = await target.committedPaths
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(target.contents(atPath: paths.writerFile), damaged)
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
                games: [game(gameName)], writerAnswer: .split(namespaceId: "ns-2")))

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

    /// A sign-in into another account keeps the target id, so the
    /// new place holds none of the blobs the state store remembers.
    func testANamespaceWithNoClaimStartsFromAFullUpload() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))

        try FileManager.default.removeItem(at: targetDirectory)
        await target.forgetCommittedPaths()

        clock.advance(3_600)
        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.stream(key(gameName))?.uploadedBlobCount, 4)
        XCTAssertEqual(target.objectPaths().filter { $0.contains("/blobs/") }.count, 4)
    }

    func testANamespaceClearThatFailsStopsTheRunBeforeASnapshotWithoutItsFiles() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        _ = await engine.run(request(games: [game(gameName)]))

        try FileManager.default.removeItem(at: targetDirectory)
        await target.forgetCommittedPaths()
        try store.database.run(
            "CREATE TRIGGER keep BEFORE DELETE ON uploaded_manifest BEGIN SELECT RAISE(ABORT, 'held'); END")

        clock.advance(3_600)
        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

    // MARK: - A state store read that fails

    func testAJoinIsNotDroppedWhenTheLastManifestDoesNotRead() async throws {
        let root = try makeGameTree(gameName)
        try write("level 3", to: root.appendingPathComponent("Game/Data/progress.bin"))
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        var joined = game(gameName)
        joined.set.runtimeWatchPaths = ["Game/Data/progress.bin"]
        _ = await engine.run(request(games: [joined]))
        try store.database.run("DROP TABLE uploaded_manifest")

        clock.advance(3_600)
        try changeTheSave(of: gameName, to: "slot one, after a relaunch")
        let next = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(next.outcome, .failed)
        XCTAssertEqual(manifestPaths(target).count, 1)
    }

    func testALastManifestRowThatDoesNotDecodeStopsNoGame() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        _ = await engine.run(request(games: [game("Alpha"), game("Bravo")]))
        try store.database.run(
            "UPDATE uploaded_manifest SET manifest = x'7b' WHERE gameKey = ?", [.text(key("Alpha"))])

        clock.advance(3_600)
        try changeTheSave(of: "Alpha", to: "slot one of Alpha, later")
        try changeTheSave(of: "Bravo", to: "slot one of Bravo, later")
        let next = await engine.run(request(games: [game("Alpha"), game("Bravo")]))

        XCTAssertEqual(next.outcome, .success)
        XCTAssertEqual(manifestPaths(target).count, 4)
    }

    func testAStalenessClockThatDoesNotReadStopsTheRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run("DROP TABLE staleness")

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.stop, .rejected(message: RestoreNotices.recordsUnavailableLine))
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

    func testADeviceRecordThatDoesNotDownloadStopsTheRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        try target.seed(path: paths.deviceFile, contents: Data("{}".utf8))
        await target.addFault(
            FakeTargetFault(
                operation: .get, error: .offline, pathContains: BackupNamespacePaths.deviceFileName))

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

    func testASweepWhoseStoredBytesDoNotReadIsAnError() async throws {
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(makeTarget(), stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run("DROP TABLE uploaded_manifest")

        do {
            _ = try await engine.sweep(
                SweepRequest(descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId))
            XCTFail("the sweep read no stored bytes and went on")
        } catch {}
    }

    func testADeleteWhoseSnapshotListDoesNotReadStaysPending() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        _ = await engine.run(request(games: [game(gameName)]))
        try store.database.run("DROP TABLE snapshot_ledger")

        let outcome = await engine.deleteBackups(
            BackupDeleteRequest(
                descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                gameKey: key(gameName)))

        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(manifestPaths(target).count, 1)
    }

    func testPendingDeletionsThatDoNotReadStopTheRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run("DROP TABLE pending_deletion")

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

    // MARK: - 8. The prune ladder, per 5.14

    func testAClaimTheLadderSweepFindsStopsTheRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let other = WriterClaim(
            namespaceId: namespaceId, deviceId: "device-b", deviceName: "iPad",
            claimedAt: clock.now)
        let observer = ClaimBeforeTheGame(
            target: target, path: paths.writerFile, claim: try other.jsonData())
        await target.addFault(
            FakeTargetFault(operation: .put, error: .outOfSpace, pathContains: "/blobs/", times: 1))
        let engine = try makeEngine(target, observer: observer)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.stop, .writerConflict(other))
        XCTAssertTrue(manifestPaths(target).isEmpty)
    }

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

    /// The cap limits what Empo stores, so it holds on a target that
    /// reports no free space too.
    func testTheCapRefusesARunOnATargetWithNoSpaceQuery() async throws {
        try makeGameTree(gameName)
        let target = makeTarget(capabilities: TargetCapabilities(canQueryQuota: false))
        let engine = try makeEngine(target)

        let result = await engine.run(request(games: [game(gameName)], capBytes: 4))

        guard case .quotaShortfall(let shortfall)? = result.stop else {
            return XCTFail("the run was not refused: \(String(describing: result.stop))")
        }
        XCTAssertEqual(shortfall.freeBytes, 4)
        XCTAssertTrue(blobPaths(target).isEmpty)
    }

    func testAGameOverTheCapLeavesTheOtherGamesToBackUp() async throws {
        try makeGameTree(gameName)
        let big = "Big Game"
        let bigRoot = try makeGameTree(big)
        let noise = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
        try noise.write(to: bigRoot.appendingPathComponent("Game/save1.dat"))
        let engine = try makeEngine(makeTarget(capabilities: TargetCapabilities(canQueryQuota: false)))

        let result = await engine.run(
            request(
                games: [game(gameName), game(big, lastPlayedAt: clock.now)],
                capBytes: 50_000))

        guard case .wroteSnapshot? = result.stream(key(gameName))?.outcome else {
            return XCTFail("the small game was not backed up: \(result.streams)")
        }
        guard case .failed? = result.stream(key(big))?.outcome else {
            return XCTFail("the big game was not stopped: \(result.streams)")
        }
        guard case .quotaShortfall(let shortfall)? = result.stop else {
            return XCTFail("the run names no shortfall: \(String(describing: result.stop))")
        }
        XCTAssertGreaterThan(shortfall.missingBytes, 0)
    }

    func testTheCapCountsTheBytesThatGoUp() async throws {
        let root = try makeGameTree(gameName)
        try write(
            String(repeating: "a", count: 200_000), to: root.appendingPathComponent("Game/save1.dat"))
        let engine = try makeEngine(makeTarget(capabilities: TargetCapabilities(canQueryQuota: false)))

        let result = await engine.run(request(games: [game(gameName)], capBytes: 20_000))

        XCTAssertEqual(result.outcome, .success, "\(String(describing: result.stop))")
    }

    private func assertASaveThatChangesBeforeItsUploadLeavesNoFalseBlob(
        sizeBytes: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let root = try makeGameTree(gameName)
        let target = makeTarget()
        let save = root.appendingPathComponent("Game/save1.dat")
        try write(String(repeating: "s", count: sizeBytes), to: save)
        let engine = try makeEngine(
            target, observer: WriteBeforeItsUpload(file: save, sizeBytes: Int64(sizeBytes)))
        var inPlace = request(games: [game(gameName)])
        inPlace.freeSpaceBytes = Int64(sizeBytes) + 1_000_000

        let result = await engine.run(inPlace)

        XCTAssertEqual(
            result.stream(key(gameName))?.partialPaths, ["Game/save1.dat"], file: file, line: line)
        for entry in try manifestOfTheLastSnapshot(of: result, on: target).entries {
            let blob = try XCTUnwrap(
                target.contents(
                    atPath: paths.blobPath(
                        hash: entry.hash, fanOutWidth: FormatDescriptor.version1FanOutWidth)),
                file: file, line: line)
            let bytes = try BlobCodec.decode(blob, algorithm: entry.compression)
            XCTAssertEqual(
                ContentHash.hex(of: bytes), entry.hash, "the blob of \(entry.path)",
                file: file, line: line)
        }
    }

    func testASaveThatChangesBeforeItsUploadGoesUpUnderItsOwnHash() async throws {
        try await assertASaveThatChangesBeforeItsUploadLeavesNoFalseBlob(sizeBytes: 1_234)
    }

    func testALargeSaveThatChangesDuringItsUploadNamesNoFalseBlob() async throws {
        try await assertASaveThatChangesBeforeItsUploadLeavesNoFalseBlob(
            sizeBytes: Int(SnapshotEngine.compressionSizeLimit) + 1)
    }

    func testTheRunWritesTheSpaceReadingItTookAfterTheUploads() async throws {
        try makeGameTree(gameName)
        let target = makeTarget(
            capabilities: TargetCapabilities(canQueryQuota: true), quotaLimitBytes: 50_000_000)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let engine = try makeEngine(target, stateURL: stateURL)

        let result = await engine.run(request(games: [game(gameName)]))

        XCTAssertEqual(result.outcome, .success)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        let status = try XCTUnwrap(store.targetStatus(targetId: targetId))
        XCTAssertEqual(status.quota?.limitBytes, 50_000_000)
        let live = try await target.quota()
        XCTAssertEqual(status.quota?.usedBytes, live?.usedBytes)
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

    /// A restore finds where a bucket file goes by the names the
    /// header lists, so a bucket missing from the list cannot
    /// restore.
    func testThePrefsStreamHeaderNamesItsRescuedSavesBuckets() async throws {
        let bucket = documents.appendingPathComponent("Rescued Saves/Lost Game", isDirectory: true)
        try write("save", to: bucket.appendingPathComponent("slot1.sav"))
        let preferences = LibraryBackupSetRequest(rescuedSavesBuckets: ["Lost Game": bucket])
        let target = makeTarget()
        let engine = try makeEngine(target)

        _ = await engine.run(request(games: [], preferences: preferences))

        let path = try XCTUnwrap(
            manifestPaths(target).first { $0.hasPrefix(paths.prefix(of: .preferences)) })
        XCTAssertEqual(try manifest(on: target, at: path).rescuedSavesBuckets, ["Lost Game"])
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

    func testADeleteLeavesTheManifestsWhenAnotherDeviceHoldsTheClaim() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let engine = try makeEngine(target)
        _ = await engine.run(request(games: [game(gameName)]))
        let other = WriterClaim(
            namespaceId: namespaceId, deviceId: "device-b", deviceName: "iPad",
            claimedAt: clock.now)
        try target.seed(path: paths.writerFile, contents: try other.jsonData())

        let outcome = await engine.deleteBackups(
            BackupDeleteRequest(
                descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                gameKey: key(gameName)))

        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(manifestPaths(target).count, 1)
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

    func testAPendingDeletionThatFailsDoesNotStopTheNextOne() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let target = makeTarget()
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let engine = try makeEngine(target, stateURL: stateURL)
        _ = await engine.run(request(games: [game("Alpha"), game("Bravo")]))

        await target.addFault(FakeTargetFault(operation: .delete, error: .offline))
        let firstAsk = clock.now
        for name in ["Alpha", "Bravo"] {
            _ = await engine.deleteBackups(
                BackupDeleteRequest(
                    descriptor: descriptor, namespaceId: namespaceId, deviceId: deviceId,
                    gameKey: key(name)))
            clock.advance(60)
        }
        await target.removeFaults()
        await target.addFault(
            FakeTargetFault(operation: .delete, error: .offline, pathContains: key("Alpha")))

        _ = await engine.run(request(games: []))

        let left = manifestPaths(target)
        XCTAssertTrue(
            left.allSatisfy { $0.hasPrefix(paths.prefix(of: .game(key: key("Alpha")))) },
            "Bravo's manifests are still there: \(left)")
        XCTAssertFalse(left.isEmpty)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        XCTAssertEqual(
            try store.pendingDeletions(targetId: descriptor.id),
            [PendingDeletion(targetId: descriptor.id, gameKey: key("Alpha"), requestedAt: firstAsk)])
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

        let arrived = await latch.waitForArrivals(4)
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
        _ = await latch.waitForArrivals(4)
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

    // MARK: - The hard stop of 7.6 during a restore

    func testARestoreStoppedDuringADownloadLeavesTheSaveAsItIs() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")

        // The format file and the manifest pass, and the first blob
        // download holds.
        let reads = target.contents(atPath: paths.formatFile) == nil ? 1 : 2
        let latch = TransferLatch(holdFrom: reads + 1)
        await target.setLatch(latch)
        let engine = RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot)
        let restore = RestoreRequest(
            targetId: targetId,
            root: "",
            namespaceId: namespaceId,
            stream: BackupStream(key: key(gameName)),
            snapshotId: snapshotId,
            choice: .restore(.wholeGame),
            destination: MemberSource(container: container(gameName)),
            freeSpaceBytes: .max)
        let running = Task { await engine.run(restore) }

        let arrived = await latch.waitForArrivals(reads + 1)
        XCTAssertTrue(arrived)
        running.cancel()
        await latch.open()
        let outcome = await running.value

        guard case .stopped(.gameLaunched, let result) = outcome else {
            return XCTFail("the restore did not stop for the game: \(outcome)")
        }
        XCTAssertEqual(result.writtenFileCount, 0)
        let save = try String(
            contentsOf: container(gameName).appendingPathComponent("Game/save1.dat"),
            encoding: .utf8)
        XCTAssertEqual(save, "played after the backup")
    }

    func testARestoreRefusesAManifestPathThatLeavesTheGame() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let manifestPath = paths.manifestPath(
            stream: BackupStream(key: key(gameName)), snapshotId: snapshotId)
        var manifest = try SnapshotManifest.decode(
            compressed: try XCTUnwrap(target.contents(atPath: manifestPath)))
        let save = try XCTUnwrap(manifest.entries.firstIndex { $0.path == "Game/save1.dat" })
        manifest.entries[save].path = "../Escaped/save1.dat"
        try target.seed(path: manifestPath, contents: try manifest.compressedData())
        try changeTheSave(of: gameName, to: "played after the backup")

        let engine = RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot)
        let outcome = await engine.run(
            RestoreRequest(
                targetId: targetId,
                root: "",
                namespaceId: namespaceId,
                stream: BackupStream(key: key(gameName)),
                snapshotId: snapshotId,
                choice: .restore(.wholeGame),
                destination: MemberSource(container: container(gameName)),
                freeSpaceBytes: .max))

        guard case .failed = outcome else {
            return XCTFail("the restore took the path: \(outcome)")
        }
        let escaped = container(gameName).deletingLastPathComponent()
            .appendingPathComponent("Escaped/save1.dat")
        XCTAssertFalse(fm.fileExists(atPath: escaped.path))
        let kept = try String(
            contentsOf: container(gameName).appendingPathComponent("Game/save1.dat"),
            encoding: .utf8)
        XCTAssertEqual(kept, "played after the backup")
    }

    func testARestoreRefusesASharedDataPathThatLeavesTheDataFolder() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let manifestPath = paths.manifestPath(
            stream: BackupStream(key: key(gameName)), snapshotId: snapshotId)
        var manifest = try SnapshotManifest.decode(
            compressed: try XCTUnwrap(target.contents(atPath: manifestPath)))
        manifest.sharedDataDirectory = "Games/Other Quest"
        try target.seed(path: manifestPath, contents: try manifest.compressedData())
        try changeTheSave(of: gameName, to: "played after the backup")

        let engine = RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot)
        let outcome = await engine.run(
            RestoreRequest(
                targetId: targetId,
                root: "",
                namespaceId: namespaceId,
                stream: BackupStream(key: key(gameName)),
                snapshotId: snapshotId,
                choice: .restore(.wholeGame),
                destination: MemberSource(container: container(gameName)),
                freeSpaceBytes: .max))

        guard case .failed = outcome else {
            return XCTFail("the restore took the path: \(outcome)")
        }
        let kept = try String(
            contentsOf: container(gameName).appendingPathComponent("Game/save1.dat"),
            encoding: .utf8)
        XCTAssertEqual(kept, "played after the backup")
    }

    func testARestoreTakesASaveWhoseNameHoldsABackslashOrAColon() async throws {
        try makeGameTree(gameName)
        let names = ["C:slot.sav", "back\\slash.sav"]
        for name in names {
            try write("saved as \(name)", to: container(gameName).appendingPathComponent("Game/\(name)"))
        }
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        for name in names {
            try fm.removeItem(at: container(gameName).appendingPathComponent("Game/\(name)"))
        }

        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot
        ).run(
            RestoreRequest(
                targetId: targetId,
                root: "",
                namespaceId: namespaceId,
                stream: BackupStream(key: key(gameName)),
                snapshotId: snapshotId,
                choice: .restore(.wholeGame),
                destination: MemberSource(container: container(gameName)),
                localFiles: try localFiles(of: gameName),
                freeSpaceBytes: .max))

        guard case .finished = outcome else {
            return XCTFail("the restore refused the names: \(outcome)")
        }
        for name in names {
            XCTAssertEqual(try gameText(name), "saved as \(name)")
        }
    }

    // MARK: - Use only this backup

    /// Every file of the container with its hash, as the app lists it.
    private func localFiles(of folderName: String) throws -> [RestoreLocalFile] {
        let root = container(folderName)
        return BackupSetResolver.files(under: root, fm: fm).map {
            RestoreLocalFile(
                root: .container, path: $0.path, size: $0.size,
                hash: try? ContentHash.hexOfFile(at: root.appendingPathComponent($0.path)))
        }
    }

    private func replace(
        with snapshotId: String, on target: FakeBackupTarget
    ) async throws -> RestoreOutcome {
        let engine = RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot)
        return await engine.run(
            RestoreRequest(
                targetId: targetId,
                root: "",
                namespaceId: namespaceId,
                stream: BackupStream(key: key(gameName)),
                snapshotId: snapshotId,
                choice: .replaceTheTree,
                destination: MemberSource(container: container(gameName)),
                localFiles: try localFiles(of: gameName),
                freeSpaceBytes: .max,
                mode: .full))
    }

    private func replaceRequest(_ snapshotId: String) throws -> RestoreRequest {
        RestoreRequest(
            targetId: targetId,
            root: "",
            namespaceId: namespaceId,
            stream: BackupStream(key: key(gameName)),
            snapshotId: snapshotId,
            choice: .replaceTheTree,
            destination: MemberSource(container: container(gameName)),
            localFiles: try localFiles(of: gameName),
            freeSpaceBytes: .max,
            mode: .full)
    }

    func testARestoreWhoseFormatFileDoesNotDownloadWritesNothing() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")
        await target.addFault(
            FakeTargetFault(operation: .get, error: .offline, pathContains: paths.formatFile))

        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot
        ).run(
            RestoreRequest(
                targetId: targetId,
                root: "",
                namespaceId: namespaceId,
                stream: BackupStream(key: key(gameName)),
                snapshotId: snapshotId,
                choice: .restore(.wholeGame),
                destination: MemberSource(container: container(gameName)),
                freeSpaceBytes: .max))

        guard case .failed = outcome else {
            return XCTFail("the restore went on without the format file: \(outcome)")
        }
        let save = try String(
            contentsOf: container(gameName).appendingPathComponent("Game/save1.dat"),
            encoding: .utf8)
        XCTAssertEqual(save, "played after the backup")
    }

    func testAFinishedReplaceWhoseRecordDoesNotClearAsksNothing() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let restore = RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run(
            "CREATE TRIGGER keep BEFORE DELETE ON intent_record BEGIN SELECT RAISE(ABORT, 'held'); END")

        let outcome =
            await restore
            .run(try replaceRequest(snapshotId))

        guard case .finished = outcome else {
            return XCTFail("the replace did not finish: \(outcome)")
        }
        let layout = BackupRootLayout(root: localRoot)
        XCTAssertNil(try RestoreResumeQuestion.unfinishedRecord(in: store, layout: layout))
        try store.database.run("DROP TRIGGER keep")
        XCTAssertNil(try RestoreResumeQuestion.unfinishedRecord(in: store, layout: layout))
        XCTAssertNil(try store.intent(kind: .interruptedRestore))
        XCTAssertFalse(fm.fileExists(atPath: layout.finishedRestoreMark.path))
    }

    func testARestoreAfterAFinishedOneWhoseRecordDidNotClearKeepsItsMark() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let stateURL = tempRoot.appendingPathComponent("state.sqlite")
        let restore = RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run(
            "CREATE TRIGGER keep BEFORE DELETE ON intent_record BEGIN SELECT RAISE(ABORT, 'held'); END")
        guard case .finished = await restore.run(try replaceRequest(snapshotId)) else {
            return XCTFail("the first replace did not finish")
        }

        let next = await restore.run(try replaceRequest(snapshotId))

        guard case .failed = next else {
            return XCTFail("the second replace did not fail: \(next)")
        }
        let layout = BackupRootLayout(root: localRoot)
        XCTAssertTrue(fm.fileExists(atPath: layout.finishedRestoreMark.path))
        XCTAssertNil(try RestoreResumeQuestion.unfinishedRecord(in: store, layout: layout))
    }

    func testAReplaceThatCannotMoveTheTreeLeavesNoRestoreRecord() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let stateURL = tempRoot.appendingPathComponent("restore.sqlite")
        let request = try replaceRequest(snapshotId)
        // A folder with no write right refuses the move of `Game/`.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container(gameName).path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container(gameName).path)
        }

        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot
        ).run(request)

        guard case .failed = outcome else {
            return XCTFail("the replace did not fail: \(outcome)")
        }
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        XCTAssertNil(try store.intent(kind: .interruptedRestore))
    }

    func testAReplaceThatCannotMoveTheTreeLeavesNoDownloadedFiles() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let request = try replaceRequest(try snapshotId(of: backup, stream: key(gameName)))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container(gameName).path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container(gameName).path)
        }

        let outcome = await RestoreEngine(
            provider: target,
            store: try BackupStateStore(url: tempRoot.appendingPathComponent("restore.sqlite")),
            localRoot: localRoot
        ).run(request)

        guard case .failed = outcome else {
            return XCTFail("the replace did not fail: \(outcome)")
        }
        let restore = BackupRootLayout(root: localRoot).restore
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: restore.path)) ?? [], [])
    }

    func testAReplaceStoppedInItsLastDownloadLeavesTheGameFolderInPlace() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let request = try replaceRequest(try snapshotId(of: backup, stream: key(gameName)))
        // The format file and the manifest pass, then the three blobs
        // of `Game/`. The last blob holds.
        let reads = target.contents(atPath: paths.formatFile) == nil ? 1 : 2
        let latch = TransferLatch(holdFrom: reads + 3)
        await target.setLatch(latch)
        let engine = RestoreEngine(
            provider: target,
            store: try BackupStateStore(url: tempRoot.appendingPathComponent("restore.sqlite")),
            localRoot: localRoot)
        let running = Task { await engine.run(request) }
        let arrived = await latch.waitForArrivals(reads + 3)
        XCTAssertTrue(arrived)
        running.cancel()
        await latch.open()

        guard case .stopped(.gameLaunched, _) = await running.value else {
            return XCTFail("the replace did not stop")
        }
        XCTAssertEqual(
            try String(
                contentsOf: container(gameName).appendingPathComponent("Game/save1.dat"),
                encoding: .utf8),
            "slot one of \(gameName)")
    }

    /// Stops the first try of a replace after one file landed in the
    /// new `Game/`, and answers the folder the old tree moved to.
    private func stopAReplaceHalfWay(
        _ snapshotId: String, on target: FakeBackupTarget, stateURL: URL
    ) async throws -> String {
        // The format file, the manifest, and the first blob pass.
        // The second blob holds.
        let reads = target.contents(atPath: paths.formatFile) == nil ? 1 : 2
        let latch = TransferLatch(holdFrom: reads + 2)
        await target.setLatch(latch)
        let first = try replaceRequest(snapshotId)
        let engine = RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot)
        let running = Task { await engine.run(first) }
        let arrived = await latch.waitForArrivals(reads + 2)
        XCTAssertTrue(arrived)
        running.cancel()
        await latch.open()
        let outcome = await running.value
        guard case .stopped = outcome else {
            return try XCTUnwrap(nil, "the first try did not stop: \(outcome)")
        }
        await target.setLatch(nil)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        var moved: String?
        if case .restore(.replaceTheTree, let name) = try store.intent(kind: .interruptedRestore)?.work {
            moved = name
        }
        let name = try XCTUnwrap(moved, "the record does not name the moved tree")
        // The engine writes only after every file is staged, so a
        // stop in a download lands before the move. A process killed
        // after the move leaves this.
        let tree = container(gameName).appendingPathComponent("Game", isDirectory: true)
        try fm.moveItem(at: tree, to: container(gameName).appendingPathComponent(name))
        try fm.createDirectory(at: tree, withIntermediateDirectories: false)
        try fm.copyItem(
            at: container(gameName).appendingPathComponent(name).appendingPathComponent("Game.ini"),
            to: tree.appendingPathComponent("Game.ini"))
        return name
    }

    func testAResumedReplaceDoesNotMoveTheHalfRestoredTreeAside() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")
        let stateURL = tempRoot.appendingPathComponent("restore.sqlite")
        let moved = try await stopAReplaceHalfWay(snapshotId, on: target, stateURL: stateURL)
        let foldersAfterTheStop = Set(try fm.contentsOfDirectory(atPath: container(gameName).path))

        var second = try replaceRequest(snapshotId)
        second.movedAsideTree = moved
        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot
        ).run(second)

        guard case .finished(let result) = outcome else {
            return XCTFail("the resume did not finish: \(outcome)")
        }
        XCTAssertEqual(result.replacedTreeName, moved)
        XCTAssertEqual(try gameText("save1.dat", in: moved), "played after the backup")
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: container(gameName).path)), foldersAfterTheStop)
    }

    func testANewReplaceAfterAStoppedOneMovesTheCurrentTreeAside() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let stateURL = tempRoot.appendingPathComponent("restore.sqlite")
        let moved = try await stopAReplaceHalfWay(snapshotId, on: target, stateURL: stateURL)
        try changeTheSave(of: gameName, to: "played after the stop")

        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot
        ).run(try replaceRequest(snapshotId))

        guard case .finished(let result) = outcome else {
            return XCTFail("the new replace did not finish: \(outcome)")
        }
        let replacedTree = try XCTUnwrap(result.replacedTreeName)
        XCTAssertNotEqual(replacedTree, moved)
        XCTAssertEqual(try gameText("save1.dat", in: replacedTree), "played after the stop")
        XCTAssertEqual(try gameText("save1.dat"), "slot one of \(gameName)")
    }

    func testAResumeMovesTheTreeWhenTheFirstTryDiedBeforeTheMove() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")
        let moved = "Game (named, not moved yet)"

        var resume = try replaceRequest(snapshotId)
        resume.movedAsideTree = moved
        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: nil), localRoot: localRoot
        ).run(resume)

        guard case .finished(let result) = outcome else {
            return XCTFail("the resume did not finish: \(outcome)")
        }
        XCTAssertEqual(result.replacedTreeName, moved)
        XCTAssertEqual(try gameText("save1.dat", in: moved), "played after the backup")
        XCTAssertEqual(try gameText("save1.dat"), "slot one of \(gameName)")
    }

    private func gameText(_ path: String, in tree: String = "Game") throws -> String {
        try String(
            contentsOf: container(gameName).appendingPathComponent("\(tree)/\(path)"),
            encoding: .utf8)
    }

    func testAReplaceWritesTheFilesThatMatchTheBackupIntoTheNewTree() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))

        let outcome = try await replace(with: snapshotId, on: target)

        guard case .finished(let result) = outcome else {
            return XCTFail("the replace did not finish: \(outcome)")
        }
        XCTAssertEqual(try gameText("Game.ini"), "[Game]\nTitle=\(gameName)\n")
        XCTAssertEqual(try gameText("save1.dat"), "slot one of \(gameName)")
        XCTAssertEqual(try gameText("autosave.sav"), "auto of \(gameName)")
        XCTAssertNil(result.replacedTreeName)
    }

    func testAReplaceOverAChangedSaveKeepsTheChangedSaveInTheMovedTree() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")

        let outcome = try await replace(with: snapshotId, on: target)

        guard case .finished(let result) = outcome else {
            return XCTFail("the replace did not finish: \(outcome)")
        }
        XCTAssertEqual(try gameText("save1.dat"), "slot one of \(gameName)")
        XCTAssertEqual(try gameText("Game.ini"), "[Game]\nTitle=\(gameName)\n")
        XCTAssertEqual(result.displacedFileCount, 0)
        let moved = try XCTUnwrap(result.replacedTreeName)
        XCTAssertEqual(try gameText("save1.dat", in: moved), "played after the backup")
        XCTAssertFalse(
            fm.fileExists(
                atPath: container(gameName).appendingPathComponent("\(moved)/Game.ini").path))
    }

    func testAReplaceKeepsTheMovedTreeWhenItHoldsALinkTheBackupDoesNotList() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try fm.createSymbolicLink(
            atPath: container(gameName).appendingPathComponent("Game/shortcut").path,
            withDestinationPath: "save1.dat")

        let outcome = try await replace(with: snapshotId, on: target)

        guard case .finished(let result) = outcome else {
            return XCTFail("the replace did not finish: \(outcome)")
        }
        let moved = try XCTUnwrap(result.replacedTreeName, "the moved tree is gone")
        let link = container(gameName).appendingPathComponent("\(moved)/shortcut").path
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), "save1.dat")
    }

    func testAReplaceKeepsTheMovedTreeWhenItHoldsAFileEmpoCannotRead() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let locked = container(gameName).appendingPathComponent("Game/locked.sav")
        try write("a save no backup holds", to: locked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let outcome = try await replace(with: snapshotId, on: target)

        guard case .finished(let result) = outcome else {
            return XCTFail("the replace did not finish: \(outcome)")
        }
        let moved = try XCTUnwrap(result.replacedTreeName, "the moved tree is gone")
        let kept = container(gameName).appendingPathComponent("\(moved)/locked.sav")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "a save no backup holds")
    }

    func testAResumedReplaceKeepsTheSavesTheGameWroteAfterTheStop() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(
            request(games: [game(gameName, isOneOff: true)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        let stateURL = tempRoot.appendingPathComponent("restore.sqlite")
        let moved = try await stopAReplaceHalfWay(snapshotId, on: target, stateURL: stateURL)
        for name in ["Game.ini", "autosave.sav", "save1.dat"] {
            try write("played after the stop", to: container(gameName).appendingPathComponent("Game/\(name)"))
        }

        var resume = try replaceRequest(snapshotId)
        resume.movedAsideTree = moved
        let outcome = await RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot
        ).run(resume)

        guard case .finished = outcome else {
            return XCTFail("the resume did not finish: \(outcome)")
        }
        XCTAssertEqual(try gameText("save1.dat"), "slot one of \(gameName)")
        let tree = container(gameName).appendingPathComponent("Game")
        let kept = try fm.contentsOfDirectory(atPath: tree.path).filter {
            (try? String(contentsOf: tree.appendingPathComponent($0), encoding: .utf8))
                == "played after the stop"
        }
        XCTAssertEqual(kept.count, 3, "the saves made after the stop are gone: \(kept)")
    }

    func testARestoreThatCannotWriteItsResumeRecordWritesNothing() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let backup = try await makeEngine(target).run(request(games: [game(gameName)]))
        let snapshotId = try snapshotId(of: backup, stream: key(gameName))
        try changeTheSave(of: gameName, to: "played after the backup")
        let stateURL = tempRoot.appendingPathComponent("restore.sqlite")
        let restore = RestoreEngine(
            provider: target, store: try BackupStateStore(url: stateURL), localRoot: localRoot)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        try store.database.run(
            "CREATE TRIGGER hold BEFORE INSERT ON intent_record BEGIN SELECT RAISE(ABORT, 'held'); END")

        let outcome =
            await restore
            .run(
                RestoreRequest(
                    targetId: targetId,
                    root: "",
                    namespaceId: namespaceId,
                    stream: BackupStream(key: key(gameName)),
                    snapshotId: snapshotId,
                    choice: .restore(.wholeGame),
                    destination: MemberSource(container: container(gameName)),
                    localFiles: try localFiles(of: gameName),
                    freeSpaceBytes: .max))

        guard case .failed = outcome else {
            return XCTFail("the restore ran with no resume record: \(outcome)")
        }
        XCTAssertEqual(try gameText("save1.dat"), "played after the backup")
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: container(gameName).appendingPathComponent("Game").path)
                .sorted(),
            ["Game.ini", "autosave.sav", "save1.dat"])
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

    func testTheRunReportsEveryGamesPlanBeforeItsFirstUpload() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let target = makeTarget()
        let recorder = RunPlanRecorder()
        let engine = try makeEngine(target, observer: recorder)

        _ = await engine.run(request(games: [game("Alpha"), game("Bravo")]))

        let plan = await recorder.plan
        let plannedAtFirstConfirm = await recorder.plannedAtFirstConfirm
        XCTAssertGreaterThan(plan.plannedBytes, 0)
        XCTAssertEqual(plannedAtFirstConfirm, plan.plannedBytes)
        XCTAssertEqual(plan.fraction, 1)
    }

    func testAGameThatStartsMidRunStopsTheRunBeforeTheNextGame() async throws {
        try makeGameTree("Alpha")
        try makeGameTree("Bravo")
        let target = makeTarget()
        let gate = RunGate(membersBeforeTheGame: 5)
        let engine = try makeEngine(target, observer: gate)

        let result = await engine.run(request(games: [game("Alpha"), game("Bravo")]))

        XCTAssertEqual(result.stop, .gameStarted)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.streams.filter { $0.streamKey != BackupStream.preferences.key }.count, 1)
        XCTAssertNil(TargetFailure.of(.gameStarted))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .gameStarted))
    }

    func testAGameThatStartsMidStreamStopsBeforeTheNextFile() async throws {
        try makeGameTree("Alpha")
        let target = makeTarget()
        let gate = RunGate(membersBeforeTheGame: 1)
        let engine = try makeEngine(target, observer: gate)

        let result = await engine.run(request(games: [game("Alpha")]))

        XCTAssertEqual(result.stop, .gameStarted)
        let confirmCount = await gate.confirmCount
        XCTAssertEqual(confirmCount, 1)
        XCTAssertTrue(result.streams.isEmpty)
    }

    func testAPauseKeepsTheTargetFailureOfAnEarlierRun() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let clock = self.clock!
        let earlier = try BackupStateStore(url: stateURL)
        try earlier.recordTargetFailure(targetId: targetId, failure: .needsSignIn, at: clock.now)
        earlier.close()
        let engine = try makeEngine(target, stateURL: stateURL)
        let latch = TransferLatch(holdFrom: 1)
        await target.setLatch(latch)

        let runRequest = request(games: [game(gameName)])
        let running = Task { await engine.run(runRequest) }
        let arrived = await latch.waitForArrivals(1)
        XCTAssertTrue(arrived)
        running.cancel()
        await latch.open()
        let result = await running.value

        XCTAssertEqual(result.stop, .paused)
        XCTAssertEqual(result.outcome, .cancelled)
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        XCTAssertEqual(try store.targetStatus(targetId: targetId)?.lastFailure?.failure, .needsSignIn)
        XCTAssertEqual(try store.runHistory().first?.end?.outcome, .cancelled)
    }

    func testAPlayThatEndsDuringTheUploadIsNotCountedAsBackedUp() async throws {
        try makeGameTree(gameName)
        let target = makeTarget()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let clock = self.clock!
        let engine = SnapshotEngine(
            provider: target,
            store: try BackupStateStore(url: stateURL),
            localRoot: localRoot,
            clock: FakeBackupClock(),
            now: { clock.now })
        // The fourth transfer is the first member's blob.
        let latch = TransferLatch(holdFrom: 4)
        await target.setLatch(latch)
        let scannedAt = clock.now

        let runRequest = request(games: [game(gameName)])
        let running = Task { await engine.run(runRequest) }
        let arrived = await latch.waitForArrivals(4)
        XCTAssertTrue(arrived)
        clock.advance(60)
        let player = try BackupStateStore(url: stateURL)
        try player.markDirty(gameKey: key(gameName), targetIds: [targetId], at: clock.now)
        player.close()
        await latch.open()
        let result = await running.value

        guard case .wroteSnapshot? = result.stream(key(gameName))?.outcome else {
            return XCTFail("the run wrote no snapshot")
        }
        let store = try BackupStateStore(url: stateURL)
        defer { store.close() }
        let staleness = try store.staleness(targetId: targetId, gameKey: key(gameName))
        let lastSuccessAt = try XCTUnwrap(staleness?.lastSuccessAt)
        XCTAssertEqual(
            lastSuccessAt.timeIntervalSince1970, scannedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try store.dirtyGames().map(\.gameKey), [key(gameName)])
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
        _ = await latch.waitForArrivals(4)

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

/// What the engine could not save.
private struct NoSnapshot: Error {}

final class NoteRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func add(_ line: String) {
        lock.lock()
        recorded.append(line)
        lock.unlock()
    }
}

/// Puts another device's claim on the target after the run checked
/// the claim, before the first game.
actor ClaimBeforeTheGame: BackupRunObserver {

    let target: FakeBackupTarget
    let path: String
    let claim: Data

    init(target: FakeBackupTarget, path: String, claim: Data) {
        self.target = target
        self.path = path
        self.claim = claim
    }

    func runPlanned(streamKey: String, bytes: Int64) {}
    func runConfirmed(streamKey: String, bytes: Int64) {}

    func runMayGoOn() -> Bool {
        try? target.seed(path: path, contents: claim)
        return true
    }
}

/// Answers as if a game had started once a set number of members
/// landed on the target.
actor RunGate: BackupRunObserver {

    private var membersBeforeTheGame: Int
    private(set) var confirmCount = 0

    init(membersBeforeTheGame: Int) {
        self.membersBeforeTheGame = membersBeforeTheGame
    }

    func runPlanned(streamKey: String, bytes: Int64) {}
    func runConfirmed(streamKey: String, bytes: Int64) { confirmCount += 1 }

    func runMayGoOn() -> Bool {
        confirmCount < membersBeforeTheGame
    }
}

/// Builds the run plan of SPEC 13.2 from what the engine reports,
/// the way `BackupRunMonitor` does on the app side.
/// Writes new bytes to one file as its blob starts to upload, the
/// way a game that saves mid-run does. The observer sees sizes only,
/// so the file has a size no other member has.
actor WriteBeforeItsUpload: BackupRunObserver {

    let file: URL
    let sizeBytes: Int64
    private var wrote = false

    init(file: URL, sizeBytes: Int64) {
        self.file = file
        self.sizeBytes = sizeBytes
    }

    func runPlanned(streamKey: String, bytes: Int64) {}

    func runConfirmed(streamKey: String, bytes: Int64) {}

    func runSendsBlob(bytes: Int64) {
        guard !wrote, bytes == sizeBytes else { return }
        wrote = true
        try? Data(repeating: UInt8(ascii: "t"), count: Int(bytes)).write(to: file)
    }
}

actor RunPlanRecorder: BackupRunObserver {

    private(set) var plan = BackupRunPlan()
    private(set) var plans: [(String, Int64)] = []
    private(set) var confirmCount = 0
    private(set) var plannedAtFirstConfirm: Int64?

    func runPlanned(streamKey: String, bytes: Int64) {
        plans.append((streamKey, bytes))
        plan.plan(streamKey: streamKey, bytes: bytes)
    }

    func runConfirmed(streamKey: String, bytes: Int64) {
        if plannedAtFirstConfirm == nil { plannedAtFirstConfirm = plan.plannedBytes }
        confirmCount += 1
        plan.confirm(streamKey: streamKey, bytes: bytes)
    }
}

/// Reads the state store at each upload start and each confirmed
/// blob.
private actor StoreWatcher: BackupRunObserver {
    struct Sighting: Sendable {
        var event: String
        var stream: String
        var record: String?
    }

    let stateURL: URL
    var seen: [Sighting] = []
    var runRowEnds: [BackupRunEnd?] = []

    init(stateURL: URL) {
        self.stateURL = stateURL
    }

    func runPlanned(streamKey: String, bytes: Int64) {}

    func runUploads(streamKey: String) {
        seen.append(Sighting(event: "uploads", stream: streamKey, record: recordGameKey()))
        if let store = try? BackupStateStore(url: stateURL) {
            runRowEnds.append((try? store.runHistory())?.first?.end)
            store.close()
        }
    }

    func runConfirmed(streamKey: String, bytes: Int64) {
        seen.append(Sighting(event: "confirmed", stream: streamKey, record: recordGameKey()))
    }

    private func recordGameKey() -> String? {
        guard let store = try? BackupStateStore(url: stateURL) else { return nil }
        defer { store.close() }
        return (try? store.intent(kind: .interruptedRun))?.gameKey
    }
}
