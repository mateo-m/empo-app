import Foundation
import XCTest

@testable import GameProbe

/// Proven coverage of SPEC 11.12, the resume question of 11.9, and
/// the preferences restore of 11.13.
final class RestoreCoverageTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(hashes: [String], mode: BackupMode) -> SnapshotManifest {
        SnapshotManifest(
            mode: mode,
            containerFolderName: "Quest",
            entries: hashes.enumerated().map { index, hash in
                SnapshotManifest.Entry(
                    root: .container, path: "Game/file-\(index)", size: 10, modifiedAt: stamp,
                    hash: hash, compression: .zlib)
            })
    }

    private func tree(_ hashes: [String]) -> [ProvenCoverage.TreeFile] {
        hashes.enumerated().map { index, hash in
            ProvenCoverage.TreeFile(path: "file-\(index)", hash: hash, sizeBytes: 10)
        }
    }

    // MARK: - Proven coverage, per 11.12

    func testAFullModeGameDropsTheFilesTheSnapshotCovers() {
        let decision = ProvenCoverage.decide(
            mode: .full,
            treeFiles: tree(["a", "b", "c"]),
            readableSnapshot: snapshot(hashes: ["a", "c"], mode: .full))

        XCTAssertEqual(decision.drop, ["file-0", "file-2"])
        XCTAssertEqual(decision.keep, ["file-1"])
        XCTAssertEqual(decision.keptBytes, 10)
        XCTAssertFalse(decision.clearsItself)
    }

    func testAFullyCoveredTreeClearsItself() {
        let decision = ProvenCoverage.decide(
            mode: .full,
            treeFiles: tree(["a", "b"]),
            readableSnapshot: snapshot(hashes: ["a", "b"], mode: .full))

        XCTAssertTrue(decision.clearsItself)
        XCTAssertEqual(decision.keptBytes, 0)
    }

    func testASlimModeGameDropsNothing() {
        let decision = ProvenCoverage.decide(
            mode: .slim,
            treeFiles: tree(["a", "b"]),
            readableSnapshot: snapshot(hashes: ["a", "b"], mode: .slim))

        XCTAssertTrue(decision.drop.isEmpty)
        XCTAssertEqual(decision.keep, ["file-0", "file-1"])
        XCTAssertEqual(decision.keptBytes, 20)
    }

    func testASnapshotThatIsUnreadableAtThatMomentDropsNothing() {
        let decision = ProvenCoverage.decide(
            mode: .full, treeFiles: tree(["a", "b"]), readableSnapshot: nil)

        XCTAssertTrue(decision.drop.isEmpty)
        XCTAssertEqual(decision.keep, ["file-0", "file-1"])
    }

    /// The escape of 5.15 is offered only where the mode leaves the
    /// tree unproven.
    func testTheOneOffFullSnapshotIsOfferedForASlimGameOnly() {
        XCTAssertTrue(ProvenCoverage.offersOneOffFullSnapshot(mode: .slim))
        XCTAssertFalse(ProvenCoverage.offersOneOffFullSnapshot(mode: .full))
    }

    // MARK: - Staged blobs, per 11.9

    func testAStagedBlobVerifiesBeforeItIsSkipped() {
        let content = Data("a save file".utf8)
        let encoded = BlobCodec.encode(content)
        let entry = SnapshotManifest.Entry(
            root: .container, path: "UserData/save.rxdata", size: Int64(content.count),
            modifiedAt: stamp, hash: ContentHash.hex(of: content),
            compression: encoded.algorithm)

        XCTAssertTrue(RestoreStaging.holds(encoded.bytes, entry: entry))
        XCTAssertFalse(RestoreStaging.holds(Data("other bytes".utf8), entry: entry))
    }

    func testOnlyTheBlobsThatAreNotStagedAreFetched() {
        let blobs = [
            RestoreBlob(hash: "a", compression: .zlib, sizeBytes: 10),
            RestoreBlob(hash: "b", compression: .zlib, sizeBytes: 20),
        ]

        XCTAssertEqual(RestoreStaging.toFetch(blobs, staged: ["a"]).map(\.hash), ["b"])
        XCTAssertTrue(RestoreStaging.toFetch(blobs, staged: ["a", "b"]).isEmpty)
    }

    // MARK: - The resume question, per 11.9 and 6.5

    func testAnInterruptedRestoreAsksWhateverItsSize() {
        let record = RestoreResumeQuestion.record(
            targetId: "target-1", gameKey: "key", snapshotId: "snap",
            scope: .wholeGame, replacesTheTree: false, at: stamp)

        XCTAssertEqual(record.kind, .interruptedRestore)
        XCTAssertEqual(record.uploadedBytes, 0)
        XCTAssertTrue(RestoreResumeQuestion.asks(record))
    }

    func testTheSameInterruptionAsksOnceAndNeverTwice() {
        var record = RestoreResumeQuestion.record(
            targetId: "target-1", gameKey: "key", snapshotId: "snap",
            scope: .wholeGame, replacesTheTree: false, at: stamp)
        XCTAssertTrue(RestoreResumeQuestion.asks(record))

        record.asked = true
        XCTAssertFalse(RestoreResumeQuestion.asks(record))
    }

    func testAnInterruptedRunIsNotARestoreQuestion() {
        let run = BackupIntentRecord(
            kind: .interruptedRun, targetId: "target-1", uploadedBytes: 200 * 1024 * 1024,
            createdAt: stamp)

        XCTAssertFalse(RestoreResumeQuestion.asks(run))
        XCTAssertFalse(RestoreResumeQuestion.asks(nil))
    }

    func testTheThreeAnswersDoWhatTheySay() {
        let resume = RestoreResumeQuestion.effect(of: .resume)
        XCTAssertTrue(resume.startsRestoreNow)
        XCTAssertTrue(resume.keepsRecord)
        XCTAssertFalse(resume.deletesStagedBlobs)

        let later = RestoreResumeQuestion.effect(of: .later)
        XCTAssertFalse(later.startsRestoreNow)
        XCTAssertTrue(later.keepsRecord)
        XCTAssertFalse(later.deletesStagedBlobs)

        let stop = RestoreResumeQuestion.effect(of: .stop)
        XCTAssertFalse(stop.startsRestoreNow)
        XCTAssertFalse(stop.keepsRecord)
        XCTAssertTrue(stop.deletesStagedBlobs)
    }

    /// An interrupted restore leaves one record, not one per
    /// interruption.
    func testAnInterruptedRestoreLeavesOneRecord() throws {
        let store = try BackupStateStore(url: temporaryDatabase())
        defer { store.close() }

        try store.saveIntent(
            RestoreResumeQuestion.record(
                targetId: "target-1", gameKey: "key", snapshotId: "snap-1",
                scope: .wholeGame, replacesTheTree: false, at: stamp))
        try store.saveIntent(
            RestoreResumeQuestion.record(
                targetId: "target-1", gameKey: "key", snapshotId: "snap-2",
                scope: .wholeGame, replacesTheTree: false,
                at: stamp.addingTimeInterval(60)))

        let record = try store.intent(kind: .interruptedRestore)
        XCTAssertEqual(record?.snapshotId, "snap-2")

        try store.markIntentAsked(kind: .interruptedRestore)
        XCTAssertFalse(RestoreResumeQuestion.asks(try store.intent(kind: .interruptedRestore)))

        try store.clearIntent(kind: .interruptedRestore)
        XCTAssertNil(try store.intent(kind: .interruptedRestore))
    }

    func testTheResumeQuestionNamesTheGame() {
        XCTAssertEqual(
            RestoreResumeQuestion.question(gameName: "Quest"),
            "A restore was interrupted. Resume Quest?")
    }

    // MARK: - The preferences restore, per 11.13

    func testTheUndoHoldsTheExportAsItStoodAndExpiresAfterSevenDays() {
        let plan = PreferenceRestore.plan(
            exported: ["theme": .string("dark")],
            localExport: ["theme": .string("light")],
            portableKeys: ["theme"],
            at: stamp)

        XCTAssertEqual(plan.undo.preferences, ["theme": .string("light")])
        XCTAssertFalse(plan.undo.isExpired(now: stamp.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertTrue(plan.undo.isExpired(now: stamp.addingTimeInterval(8 * 24 * 60 * 60)))
    }

    func testTheUndoSurvivesItsJSONCodec() throws {
        let undo = PreferenceUndoFile(
            savedAt: stamp, preferences: ["theme": .string("light"), "count": .int(3)])
        let read = try PreferenceUndoFile.decode(json: try undo.jsonData())

        XCTAssertEqual(read, undo)
    }

    func testADeviceLocalKeyDoesNotRestore() {
        let plan = PreferenceRestore.plan(
            exported: ["theme": .string("dark"), "debugMode": .bool(true)],
            localExport: [:],
            portableKeys: ["theme", "interfaceHaptics"],
            at: stamp)

        XCTAssertNil(plan.write["debugMode"])
        XCTAssertEqual(plan.skippedKeys, ["debugMode"])
    }

    // MARK: - Helpers

    private func temporaryDatabase() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-restore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.sqlite")
    }
}
