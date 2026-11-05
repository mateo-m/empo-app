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

    // MARK: - Speed

    func testTheScanReadsTheManifestsSideBySide() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"], snapshotsEach: 12)
        let slow = SlowTarget(wrapping: target)

        let namespaces = try await RestoreScan(provider: slow, descriptor: descriptor).namespaces()

        XCTAssertEqual(namespaces.first?.gameRows.count, 12)
        let mostAtOnce = await slow.mostAtOnce
        XCTAssertGreaterThan(mostAtOnce, 1, "the scan read one manifest at a time")
        XCTAssertLessThanOrEqual(mostAtOnce, RestoreScan.readsAtOnce)
    }

    // MARK: - The namespace list, per 13.9

    func testTheDeviceListReadsOnlyTheDeviceRecords() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest", "Other"], snapshotsEach: 3)
        try seed(namespace: "ns2", deviceName: "iPhone", games: ["Quest"])
        let ns1 = BackupNamespacePaths(root: descriptor.root, namespaceId: "ns1")
        try target.seed(path: ns1.blobPath(hash: "abcdef", fanOutWidth: 2), contents: Data(count: 500))

        let rows = try await scan().namespaceRows(thisNamespaceId: "ns2", thisDeviceId: "d-ns1")

        let readPaths = await target.readPaths
        XCTAssertEqual(Set(readPaths), [ns1.deviceFile, ns1.inNamespace("ns2").deviceFile])
        XCTAssertEqual(rows.map(\.namespaceId), ["ns1", "ns2"])

        let ipad = try XCTUnwrap(rows.first)
        XCTAssertEqual(ipad.deviceName, "iPad")
        XCTAssertEqual(ipad.snapshotCount, 6)
        XCTAssertEqual(ipad.gameCount, 2)
        XCTAssertEqual(ipad.oldestSnapshotAt, stamp)
        XCTAssertEqual(ipad.newestSnapshotAt, stamp.addingTimeInterval(120))
        let stored = try await target.list(prefix: ns1.namespacePrefix + "/")
        XCTAssertEqual(ipad.totalBytes, stored.reduce(0) { $0 + $1.sizeBytes })
        XCTAssertGreaterThan(try XCTUnwrap(ipad.totalBytes), 500)
        XCTAssertFalse(ipad.isThisDevice)
        XCTAssertTrue(ipad.isEarlierSpace)

        let iphone = try XCTUnwrap(rows.last)
        XCTAssertTrue(iphone.isThisDevice)
        XCTAssertFalse(iphone.isEarlierSpace)
    }

    func testTheDeviceListLeavesOutASizeTheListingCannotGive() async throws {
        try seed(namespace: "ns1", deviceName: "iPad", games: ["Quest"])
        let icloud = FakeBackupTarget(
            directory: tempRoot, capabilities: ICloudDrive.capabilities, clock: FakeBackupClock())

        let rows = try await RestoreScan(provider: icloud, descriptor: descriptor)
            .namespaceRows(thisNamespaceId: nil, thisDeviceId: nil)

        XCTAssertEqual(rows.first?.snapshotCount, 1)
        XCTAssertNil(rows.first?.totalBytes)
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

/// A target where each read takes a moment, so reads that overlap
/// show in `mostAtOnce`.
private actor SlowTarget: BackupProvider {

    let inner: FakeBackupTarget
    nonisolated let capabilities = TargetCapabilities()
    private var running = 0
    private(set) var mostAtOnce = 0

    init(wrapping inner: FakeBackupTarget) { self.inner = inner }

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        try await inner.list(prefix: prefix)
    }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {
        try await inner.put(localFile: localFile, path: path)
    }

    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        try await inner.confirm(path: path)
    }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        try? await Task.sleep(for: .milliseconds(20))
        running -= 1
        try await inner.get(path: path, localFile: localFile)
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        try await inner.delete(paths: paths)
    }

    func quota() async throws(BackupProviderError) -> QuotaReading? { nil }
}
