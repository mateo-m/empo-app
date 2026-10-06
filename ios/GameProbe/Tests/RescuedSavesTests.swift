import Foundation
import XCTest

@testable import GameProbe

final class RescuedSavesTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("RescuedSavesTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Failure fixtures drop permissions. Restore them so the
        // temp root always deletes cleanly.
        try? GameTreeUpdate.normalizeOwnerWritable(at: tempRoot)
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBucket(
        _ name: String, identity: String?, files: [String: String] = [:]
    ) throws -> URL {
        let bucket = tempRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        if let identity {
            XCTAssertTrue(
                RescuedSaves.writeMarker(.init(folderName: identity), inBucket: bucket))
        }
        for (relativePath, content) in files {
            let url = bucket.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return bucket
    }

    private func contents(_ root: URL, _ relativePath: String) -> String? {
        try? String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Marker

    func testMarkerRoundTrip() throws {
        let bucket = try makeBucket("My Custom Name", identity: nil)
        let identity = RescuedSaves.Identity(folderName: "Pokemon Example")

        XCTAssertTrue(RescuedSaves.writeMarker(identity, inBucket: bucket))

        XCTAssertEqual(RescuedSaves.readMarker(inBucket: bucket), identity)
    }

    func testReadMarkerReturnsNilForMissingOrMalformedFile() throws {
        let bucket = try makeBucket("No Marker", identity: nil)
        XCTAssertNil(RescuedSaves.readMarker(inBucket: bucket))

        try "not json".write(
            to: bucket.appendingPathComponent(RescuedSaves.markerName),
            atomically: true, encoding: .utf8)
        XCTAssertNil(RescuedSaves.readMarker(inBucket: bucket))
    }

    // MARK: - The backup exclusion of SPEC 5.13

    func testANewBucketIsNotExcludedFromBackup() throws {
        let bucket = try makeBucket("Fixture Quest", identity: "Fixture Quest")

        XCTAssertFalse(RescuedSaves.isExcludedFromBackup(bucket: bucket))
    }

    func testTheDeleteMarksTheBucketOutOfTheBackupSet() throws {
        let bucket = try makeBucket("Fixture Quest", identity: "Fixture Quest")

        XCTAssertTrue(RescuedSaves.excludeFromBackup(bucket: bucket))

        XCTAssertTrue(RescuedSaves.isExcludedFromBackup(bucket: bucket))
        // The exclusion keeps the identity the rescue wrote, so the
        // bucket still matches its game on this device.
        XCTAssertEqual(
            RescuedSaves.readMarker(inBucket: bucket)?.folderName, "Fixture Quest")
    }

    func testABucketWithNoMarkerStillTakesTheExclusion() throws {
        let bucket = try makeBucket("Orphan", identity: nil)

        XCTAssertTrue(RescuedSaves.excludeFromBackup(bucket: bucket))
        XCTAssertTrue(RescuedSaves.isExcludedFromBackup(bucket: bucket))
    }

    func testAnExcludedBucketLeavesTheBackupSet() throws {
        let bucket = try makeBucket(
            "Fixture Quest", identity: "Fixture Quest", files: ["Save1.rxdata": "slot"])
        let request = LibraryBackupSetRequest(rescuedSavesBuckets: ["Fixture Quest": bucket])
        XCTAssertFalse(BackupSetResolver.resolveLibraryStream(request).members.isEmpty)

        RescuedSaves.excludeFromBackup(bucket: bucket)

        // The saves the delete of 5.13 drained do not go back to the
        // remote on the next run.
        XCTAssertTrue(BackupSetResolver.resolveLibraryStream(request).members.isEmpty)
    }

    // MARK: - Matching

    func testMatchingPrefersTheMarkerIdentityOverTheBucketName() throws {
        // Named by a custom title. The marker carries the INI-derived
        // folder name a re-import resolves to.
        let bucket = try makeBucket("My Cool Nickname", identity: "Pokemon Example")

        let matches = RescuedSaves.matchingBuckets(
            in: tempRoot, folderName: "Pokemon Example")

        XCTAssertEqual(matches, [bucket])
    }

    func testMatchingIsCaseInsensitive() throws {
        let bucket = try makeBucket("nickname", identity: "POKEMON EXAMPLE")

        XCTAssertEqual(
            RescuedSaves.matchingBuckets(in: tempRoot, folderName: "pokemon example"),
            [bucket])
    }

    func testMarkedBucketNeverMatchesByItsOwnName() throws {
        // The marker is authoritative: a bucket named like the
        // wanted game but marked as ANOTHER game belongs to that
        // other game.
        _ = try makeBucket("Pokemon Example", identity: "Some Other Game")

        XCTAssertEqual(
            RescuedSaves.matchingBuckets(in: tempRoot, folderName: "Pokemon Example"), [])
    }

    func testUnmarkedBucketMatchesByDirectoryName() throws {
        let bucket = try makeBucket("Pokemon Example", identity: nil)
        _ = try makeBucket("Unrelated Game", identity: nil)

        XCTAssertEqual(
            RescuedSaves.matchingBuckets(in: tempRoot, folderName: "pokemon example"),
            [bucket])
    }

    func testMojibakeEraBucketMatchesTheCorrectedFolderName() throws {
        guard DirectoryNameMatch.legacyMojibakeRendering(of: "Pokémon Empyrean") != nil else {
            try skipOrFail("Legacy encodings are unavailable on this platform")
        }
        // Rescued before the INI decode fix: bucket and marker both
        // carry the mojibake name. The re-import arrives under the
        // corrected name and must still find it.
        let marked = try makeBucket("Pok駑on Empyrean", identity: "Pok駑on Empyrean")
        let unmarked = try makeBucket("Pok駑on Empyrean 2", identity: nil)
        _ = unmarked
        let matches = RescuedSaves.matchingBuckets(
            in: tempRoot, folderName: "Pokémon Empyrean", fm: fm)
        XCTAssertEqual(matches, [marked])
    }

    func testMatchingReturnsAllMatchesSortedAndSkipsFiles() throws {
        let second = try makeBucket("Second Nickname", identity: "Pokemon Example")
        let first = try makeBucket("First Nickname", identity: "Pokemon Example")
        try "loose file".write(
            to: tempRoot.appendingPathComponent("Pokemon Example"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(
            RescuedSaves.matchingBuckets(in: tempRoot, folderName: "Pokemon Example"),
            [first, second])
    }

    func testMatchingInMissingRootReturnsEmpty() {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(RescuedSaves.matchingBuckets(in: missing, folderName: "x"), [])
    }

    // MARK: - Restore

    func testRestoreDrainsIntoGameRootAndRemovesTheEmptiedBucket() throws {
        let bucket = try makeBucket(
            "Nickname", identity: "Pokemon Example",
            files: [
                "Save A.rxdata": "slot a",
                "save/slot1.rxdata": "slot 1",
            ])
        let gameRoot = tempRoot.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(at: gameRoot, withIntermediateDirectories: true)

        let outcome = RescuedSaves.restore(from: bucket, into: gameRoot)

        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(contents(gameRoot, "Save A.rxdata"), "slot a")
        XCTAssertEqual(contents(gameRoot, "save/slot1.rxdata"), "slot 1")
        // The marker never lands in the game tree, and the emptied
        // bucket is gone.
        XCTAssertFalse(
            fm.fileExists(atPath: gameRoot.appendingPathComponent(RescuedSaves.markerName).path))
        XCTAssertFalse(fm.fileExists(atPath: bucket.path))
    }

    func testRestoreNeverClobbersANewerFileInTheGameTree() throws {
        let bucket = try makeBucket(
            "Nickname", identity: "Pokemon Example",
            files: ["Save A.rxdata": "rescued"])
        let gameRoot = tempRoot.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let installed = gameRoot.appendingPathComponent("Save A.rxdata")
        try "shipped".write(to: installed, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: bucket.appendingPathComponent("Save A.rxdata").path)

        let outcome = RescuedSaves.restore(from: bucket, into: gameRoot)

        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(contents(gameRoot, "Save A.rxdata"), "shipped")
        XCTAssertEqual(
            contents(gameRoot, LegacyDataDrain.displacedName(for: "Save A.rxdata")),
            "rescued")
    }

    #if canImport(Darwin)
    func testPartialRestoreRewritesTheMarkerForTheNextAttempt() throws {
        // An unlistable subdirectory makes the drain fail on
        // that entry. The bucket must stay identifiable.
        let bucket = try makeBucket(
            "Nickname", identity: "Pokemon Example",
            files: [
                "Save A.rxdata": "slot a",
                "save/slot1.rxdata": "slot 1",
            ])
        let gameRoot = tempRoot.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(
            at: gameRoot.appendingPathComponent("save", isDirectory: true),
            withIntermediateDirectories: true)
        try fm.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: bucket.appendingPathComponent("save").path)

        let outcome = RescuedSaves.restore(from: bucket, into: gameRoot)

        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(contents(gameRoot, "Save A.rxdata"), "slot a")
        XCTAssertEqual(
            RescuedSaves.readMarker(inBucket: bucket),
            RescuedSaves.Identity(folderName: "Pokemon Example"))
    }
    #endif
}
