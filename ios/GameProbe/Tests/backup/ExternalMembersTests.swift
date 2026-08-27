import Foundation
import XCTest

@testable import GameProbe

/// The members outside the container, per SPEC 4.5: the shared data
/// directory and the Rescued Saves buckets.
final class ExternalMembersTests: XCTestCase {

    private var documents: URL!

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-members-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: documents)
    }

    private func makeContainer(_ folderName: String) throws -> URL {
        let games = documents.appendingPathComponent("Games", isDirectory: true)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let container = games.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.copyItem(at: BackupFixtures.url("container"), to: container)
        return container
    }

    private func makeSharedData(_ components: String) throws -> URL {
        let shared = documents.appendingPathComponent(components, isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("shared save bytes".utf8).write(
            to: shared.appendingPathComponent("Game.rxdata"))
        return shared
    }

    // MARK: - The recorded path

    func testTheHeaderRecordsThePathRelativeToDocuments() throws {
        let container = try makeContainer("Fixture Quest")
        let shared = try makeSharedData("Data/kikiyama/yumenikki")

        let set = BackupSetResolver.resolve(
            GameBackupSetRequest(
                containerURL: container,
                mode: .slim,
                sharedDataDirectory: shared,
                documentsRoot: documents))

        XCTAssertEqual(set.sharedDataDirectory, "Data/kikiyama/yumenikki")
    }

    func testARecordedPathRebuildsOnAnotherDevice() {
        let elsewhere = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/B/Documents")

        let url = ExternalMembers.url(
            ofRecordedPath: "Data/kikiyama/yumenikki", documentsRoot: elsewhere)

        XCTAssertEqual(url.path, "\(elsewhere.path)/Data/kikiyama/yumenikki")
    }

    // MARK: - One directory, two games, per 4.5

    func testTwoGamesThatShareADirectoryRecordItAndTheStorageKeysItOnce() throws {
        let shared = try makeSharedData("Data/kikiyama/yumenikki")
        let first = try makeContainer("Fixture Quest")
        let second = try makeContainer("Fixture Quest 2")

        func resolve(_ container: URL) -> GameBackupSet {
            BackupSetResolver.resolve(
                GameBackupSetRequest(
                    containerURL: container,
                    mode: .slim,
                    sharedDataDirectory: shared,
                    documentsRoot: documents))
        }

        let one = resolve(first)
        let other = resolve(second)

        // Both games record the link, per 4.5.
        XCTAssertEqual(one.sharedDataDirectory, "Data/kikiyama/yumenikki")
        XCTAssertEqual(other.sharedDataDirectory, one.sharedDataDirectory)

        // The two identities stay apart.
        XCTAssertNotEqual(
            GameIdentity(folderName: "Fixture Quest").gameKey,
            GameIdentity(folderName: "Fixture Quest 2").gameKey)

        // The storage stays path-keyed underneath, so the file
        // uploads once: one path under one root, and one blob.
        let members = one.members(under: .sharedData)
        XCTAssertEqual(members.map(\.path), other.members(under: .sharedData).map(\.path))
        let hash = try ContentHash.hexOfFile(at: shared.appendingPathComponent("Game.rxdata"))
        XCTAssertEqual(
            Set(members.map { _ in BackupKeys.blobPath(hash: hash, fanOutWidth: 2) }).count, 1)
    }

    // MARK: - A path that moved, per 4.5

    func testAPathThatMovedIsRecordedAndNothingWarns() {
        func snapshot(_ path: String) -> SnapshotManifest {
            SnapshotManifest(
                mode: .full,
                containerFolderName: "Fixture Quest",
                versionMarker: SnapshotManifest.VersionMarker(fileCount: 8, totalSize: 400),
                sharedDataDirectory: path)
        }
        let older = snapshot("Data/kikiyama/yumenikki")
        let newer = snapshot("Data/kikiyama/yumenikki 2")

        let history = ExternalMembers.sharedDataHistory(
            ofSnapshotsOldestFirst: [older, newer])

        // The newest path is what a restore offers. The old data
        // stays in the game's history.
        XCTAssertEqual(history.current, "Data/kikiyama/yumenikki 2")
        XCTAssertEqual(history.previous, ["Data/kikiyama/yumenikki"])

        // A move alerts nobody, and it warns nobody: the marker is
        // what 4.4 warns on, and the tree did not change.
        XCTAssertFalse(
            VersionMarkerBuilder.warnsBeforeRestore(
                mode: .full,
                snapshot: newer.versionMarker,
                local: older.versionMarker))
    }

    func testAPathThatCameBackIsCurrentAgain() {
        func snapshot(_ path: String) -> SnapshotManifest {
            SnapshotManifest(
                mode: .slim, containerFolderName: "Fixture Quest", sharedDataDirectory: path)
        }

        let history = ExternalMembers.sharedDataHistory(
            ofSnapshotsOldestFirst: [
                snapshot("Data/one"), snapshot("Data/two"), snapshot("Data/one"),
            ])

        XCTAssertEqual(history.current, "Data/one")
        XCTAssertEqual(history.previous, ["Data/two"])
    }

    func testAGameWithNoSharedPathHasNoHistory() {
        let history = ExternalMembers.sharedDataHistory(
            ofSnapshotsOldestFirst: [
                SnapshotManifest(mode: .slim, containerFolderName: "Fixture Quest")
            ])

        XCTAssertNil(history.current)
        XCTAssertTrue(history.previous.isEmpty)
    }

    // MARK: - The Rescued Saves buckets, per 4.5

    func testTheBucketsThatMatchTheGameAreRecorded() throws {
        let container = try makeContainer("Fixture Quest")
        let buckets = BackupFixtures.url("rescued")
        let matching = RescuedSaves.matchingBuckets(in: buckets, folderName: "Fixture Quest")
        XCTAssertEqual(matching.map(\.lastPathComponent), ["Fixture Quest"])

        let set = BackupSetResolver.resolve(
            GameBackupSetRequest(
                containerURL: container,
                mode: .slim,
                documentsRoot: documents,
                rescuedSavesBuckets: ["Fixture Quest": matching[0]]))

        XCTAssertEqual(set.rescuedSavesBuckets, ["Fixture Quest"])
        XCTAssertEqual(
            set.members(under: .rescuedSaves).map(\.path),
            ["Fixture Quest/\(RescuedSaves.markerName)", "Fixture Quest/Save1.rxdata"])
    }
}
