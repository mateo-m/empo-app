import Foundation
import XCTest

@testable import GameProbe

/// The target descriptors of SPEC 8.8.
final class TargetDescriptorTests: XCTestCase {

    private var tempRoot: URL!

    private let descriptor = TargetDescriptor(
        id: "target-dropbox-1",
        provider: .dropbox,
        label: "My Dropbox",
        accountHint: "player@example.com",
        root: "/Apps/Empo/",
        sizeThresholdBytes: 512 * 1024 * 1024,
        capBytes: 20 * 1024 * 1024 * 1024,
        isPaused: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetDescriptorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testADescriptorRoundTripsThroughTargetsJSON() throws {
        var file = TargetDescriptorFile()
        file.targets = [descriptor]

        try file.write(applicationSupport: tempRoot)
        let read = try TargetDescriptorFile.read(applicationSupport: tempRoot)

        XCTAssertEqual(read, file)
        XCTAssertEqual(read.targets.first, descriptor)
    }

    func testTargetsJSONSitsBesideTheBackupRoot() throws {
        try TargetDescriptorFile(targets: [descriptor]).write(applicationSupport: tempRoot)

        let url = tempRoot.appendingPathComponent("targets.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testADescriptorCarriesTheEightNonSecretFieldsAndNothingElse() throws {
        let data = try TargetDescriptorFile(targets: [descriptor]).jsonData()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(object["targets"] as? [[String: Any]])

        XCTAssertEqual(
            Set(targets[0].keys),
            [
                "id", "provider", "label", "accountHint", "root",
                "sizeThresholdBytes", "capBytes", "isPaused",
            ])
    }

    func testNoFieldOfTheFileReadsLikeASecret() throws {
        let data = try TargetDescriptorFile(targets: [descriptor]).jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()

        for word in ["token", "secret", "password", "refresh", "accesskey", "privatekey"] {
            XCTAssertFalse(text.contains(word), "the descriptor must not carry a \(word)")
        }
    }

    func testTheSyncCopyDropsTheAccountHint() {
        let shared = descriptor.forSyncDocument()

        XCTAssertNil(shared.accountHint)
        XCTAssertEqual(shared.label, descriptor.label)
        XCTAssertEqual(shared.root, descriptor.root)
        XCTAssertEqual(shared.capBytes, descriptor.capBytes)
        XCTAssertEqual(shared.sizeThresholdBytes, descriptor.sizeThresholdBytes)
    }

    func testTheArrivingCopyKeepsThisDevicesAccountHint() {
        var incoming = descriptor.forSyncDocument()
        incoming.label = "the other name"
        incoming.isPaused = true

        let kept = descriptor.withSyncedFields(from: incoming)

        XCTAssertEqual(kept.accountHint, descriptor.accountHint)
        XCTAssertEqual(kept.label, "the other name")
        XCTAssertTrue(kept.isPaused)
    }

    func testADescriptorWithoutAnAccountHintIsAPlaceholder() {
        XCTAssertFalse(descriptor.isPlaceholder)
        XCTAssertTrue(descriptor.forSyncDocument().isPlaceholder)
    }

    func testAMissingTargetsFileReadsAsAnEmptyOne() throws {
        let file = try TargetDescriptorFile.read(applicationSupport: tempRoot)

        XCTAssertEqual(file.version, TargetDescriptorFile.currentVersion)
        XCTAssertTrue(file.targets.isEmpty)
    }

    func testEveryV1ProviderHasAName() {
        XCTAssertEqual(BackupProviderKind.allCases.count, 6)
        XCTAssertEqual(
            Set(BackupProviderKind.allCases.map(\.rawValue)),
            ["icloud-drive", "dropbox", "google-drive", "s3", "webdav", "sftp"])
    }
}
