import Foundation
import XCTest

@testable import GameProbe

/// The provider paths of SPEC 5.1, joined to the fixed root of 8.7.
final class BackupNamespacePathsTests: XCTestCase {

    private let paths = BackupNamespacePaths(root: "", namespaceId: "ns-1")
    private let underFolder = BackupNamespacePaths(root: "Apps/Empo", namespaceId: "ns-1")

    func testAnEmptyRootPutsEmpoAtTheTop() {
        XCTAssertEqual(paths.formatFile, "Empo/format.json")
        XCTAssertEqual(paths.writerFile, "Empo/devices/ns-1/writer.json")
        XCTAssertEqual(paths.deviceFile, "Empo/devices/ns-1/device.json")
        XCTAssertEqual(paths.blobsPrefix, "Empo/devices/ns-1/blobs")
    }

    func testARootOpensEveryPath() {
        XCTAssertEqual(underFolder.formatFile, "Apps/Empo/Empo/format.json")
        XCTAssertEqual(underFolder.gamesPrefix, "Apps/Empo/Empo/devices/ns-1/games")
    }

    func testTheBlobPathFansOutByTheWidthTheFormatStates() {
        let hash = String(repeating: "a", count: 64)

        XCTAssertEqual(
            paths.blobPath(hash: hash, fanOutWidth: 2),
            "Empo/devices/ns-1/blobs/aa/\(hash)")
        XCTAssertEqual(
            paths.blobPath(hash: hash, fanOutWidth: 3),
            "Empo/devices/ns-1/blobs/aaa/\(hash)")
    }

    func testAStreamPrefixClosesWithASeparator() {
        // Without the closing separator a prefix match on one game
        // key could reach a second key that opens with it.
        XCTAssertTrue(paths.prefix(of: .game(key: "abc")).hasSuffix("/"))
        XCTAssertTrue(paths.prefix(of: .preferences).hasSuffix("/"))
    }

    func testThePreferencesStreamHasItsOwnDirectory() {
        XCTAssertEqual(paths.prefix(of: .preferences), "Empo/devices/ns-1/prefs/")
        XCTAssertEqual(paths.prefix(of: .game(key: "abc")), "Empo/devices/ns-1/games/abc/")
    }

    func testTheManifestPathCarriesTheSnapshotId() {
        XCTAssertEqual(
            paths.manifestPath(stream: .game(key: "abc"), snapshotId: "20231114T000000Z-0000aa"),
            "Empo/devices/ns-1/games/abc/20231114T000000Z-0000aa.json")
    }

    func testAManifestPathReadsBackItsSnapshotId() {
        let id = BackupKeys.makeSnapshotId(date: Date(timeIntervalSince1970: 1_699_920_000))
        let path = paths.manifestPath(stream: .preferences, snapshotId: id)

        XCTAssertEqual(BackupNamespacePaths.snapshotId(ofManifestPath: path), id)
    }

    func testABlobPathIsNoManifestPath() {
        XCTAssertNil(
            BackupNamespacePaths.snapshotId(
                ofManifestPath: paths.blobPath(
                    hash: String(repeating: "a", count: 64), fanOutWidth: 2)))
        XCTAssertNil(BackupNamespacePaths.snapshotId(ofManifestPath: paths.writerFile))
    }

    func testASplitKeepsTheRootAndChangesTheNamespace() {
        let split = paths.inNamespace("ns-2")

        XCTAssertEqual(split.root, paths.root)
        XCTAssertEqual(split.blobsPrefix, "Empo/devices/ns-2/blobs")
    }

    func testTheStreamThatBelongsToNoGameHasAKeyOfItsOwn() {
        XCTAssertEqual(BackupStream.preferences.key, BackupStream.preferencesKey)
        XCTAssertEqual(BackupStream(key: BackupStream.preferencesKey), .preferences)
        XCTAssertEqual(BackupStream(key: "abc"), .game(key: "abc"))
    }
}
