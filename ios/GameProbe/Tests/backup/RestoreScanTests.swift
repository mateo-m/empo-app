import Foundation
import XCTest

@testable import GameProbe

/// What the two manual doors of SPEC 11.3 read off a target.
final class RestoreScanTests: XCTestCase {

    private var tempRoot: URL!
    private var target: FakeBackupTarget!
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private let descriptor = TargetDescriptor(
        id: "t1", provider: .webdav, label: "Server", root: "")

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreScanTests-\(UUID().uuidString)", isDirectory: true)
        target = FakeBackupTarget(
            directory: tempRoot, clock: FakeBackupClock())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func seed(
        namespace: String, deviceName: String, games: [String], snapshotsEach: Int = 1
    ) throws {
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespace)
        let record = DeviceRecord(
            deviceId: "d-\(namespace)", model: "iPad", name: deviceName, lastWriteAt: stamp)
        try target.seed(path: paths.deviceFile, contents: try record.jsonData())

        for folderName in games {
            for index in 0..<snapshotsEach {
                let manifest = SnapshotManifest(
                    mode: .slim,
                    containerFolderName: folderName,
                    entries: [
                        SnapshotManifest.Entry(
                            root: .container, path: "Save/file\(index)", size: 10,
                            modifiedAt: stamp, hash: "h\(index)", compression: .zlib)
                    ])
                let id = BackupKeys.snapshotId(
                    date: stamp.addingTimeInterval(Double(index) * 60), suffix: "0a1b2c")
                try target.seed(
                    path: paths.manifestPath(
                        stream: .game(key: manifest.gameKey), snapshotId: id),
                    contents: try manifest.compressedData())
            }
        }
    }

    private func scan() -> RestoreScan {
        RestoreScan(provider: target, descriptor: descriptor)
    }

    // MARK: - The door of one game, per 11.3

    func testOneGameReadsNoManifestOfAnotherGame() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest", "Other"])
        try seed(namespace: "ns2", deviceName: "iPhone", games: ["Quest", "Other"])

        let key = BackupKeys.gameKey(containerFolderName: "Quest")
        let rows = try await scan().rows(of: .game(key: key))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.deviceName)), ["iPad", "iPhone"])
        XCTAssertTrue(rows.allSatisfy { $0.identity.containerFolderName == "Quest" })

        let manifests = await target.readPaths.filter { $0.hasSuffix(".json") }
            .filter { !$0.hasSuffix(BackupNamespacePaths.deviceFileName) }
        XCTAssertTrue(
            manifests.allSatisfy { $0.contains("/games/\(key)/") },
            "the door of one game read \(manifests)")
    }

    func testTheRowsOfOneGameCarryTheVersionMarkerFlag() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"])
        let key = BackupKeys.gameKey(containerFolderName: "Quest")

        let same = try await scan().rows(
            of: .game(key: key), localMarker: SnapshotManifest.VersionMarker())
        XCTAssertEqual(same.first?.versionMarkerDiffers, false)

        let other = try await scan().rows(
            of: .game(key: key),
            localMarker: SnapshotManifest.VersionMarker(fileCount: 7))
        XCTAssertEqual(other.first?.versionMarkerDiffers, true)
    }

    func testAGameWithNoSnapshotAnswersNoRow() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"])
        let rows = try await scan().rows(
            of: .game(key: BackupKeys.gameKey(containerFolderName: "Missing")))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - The browser of one namespace, per 13.9

    func testOneNamespaceReadsNoOtherNamespace() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"])
        try seed(namespace: "ns2", deviceName: "iPhone", games: ["Other"])

        let scanned = try await scan().namespace("ns1")

        XCTAssertEqual(scanned.deviceName, "iPad")
        XCTAssertEqual(scanned.gameRows.count, 1)
        let read = await target.readPaths
        XCTAssertTrue(read.allSatisfy { $0.contains("/devices/ns1/") }, "it read \(read)")
    }

    func testEveryNamespaceIsListedInOrder() async throws {
        try seed(namespace: "ns2", deviceName: "iPhone", games: ["Quest"])
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"])

        let ids = try await scan().namespaceIds()
        XCTAssertEqual(ids, ["ns1", "ns2"])
        let names = try await scan().namespaces().map(\.deviceName)
        XCTAssertEqual(names, ["iPad", "iPhone"])
    }

    func testANamespaceWithNoDeviceRecordTakesItsIdAsTheName() async throws {
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: "ns9")
        let manifest = SnapshotManifest(mode: .slim, containerFolderName: "Quest")
        try target.seed(
            path: paths.manifestPath(
                stream: .game(key: manifest.gameKey),
                snapshotId: BackupKeys.snapshotId(date: stamp, suffix: "0a1b2c")),
            contents: try manifest.compressedData())

        let scanned = try await scan().namespace("ns9")
        XCTAssertEqual(scanned.deviceName, "ns9")
        XCTAssertNil(scanned.deviceId)
        XCTAssertEqual(scanned.gameRows.first?.deviceName, "ns9")
    }
}
