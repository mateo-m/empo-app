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
        accountName: "Player One",
        accountPhoto: URL(string: "https://photos.example.com/player.jpg"),
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

    func testADescriptorCarriesTheTenNonSecretFieldsAndNothingElse() throws {
        let data = try TargetDescriptorFile(targets: [descriptor]).jsonData()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(object["targets"] as? [[String: Any]])

        XCTAssertEqual(
            Set(targets[0].keys),
            [
                "id", "provider", "label", "accountHint", "accountName", "accountPhoto", "root",
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
        XCTAssertNil(shared.accountName)
        XCTAssertNil(shared.accountPhoto)
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
        XCTAssertEqual(kept.accountName, descriptor.accountName)
        XCTAssertEqual(kept.accountPhoto, descriptor.accountPhoto)
        XCTAssertEqual(kept.label, "the other name")
        XCTAssertTrue(kept.isPaused)
    }

    func testATargetsFileFromBeforeTheAccountFieldsStillReads() throws {
        let old = Data(
            #"{"id":"t","provider":"dropbox","label":"Dropbox","accountHint":"this account","root":"","isPaused":false}"#
                .utf8)
        let read = try JSONDecoder().decode(TargetDescriptor.self, from: old)

        XCTAssertEqual(read.accountHint, "this account")
        XCTAssertNil(read.accountName)
        XCTAssertNil(read.accountPhoto)
    }

    func testTheSignedInAccountNamesTheTargetByItsEmail() {
        var target = TargetDescriptor(
            id: "t", provider: .googleDrive, label: "Google Drive",
            accountHint: "this account", root: "")
        target.take(BackupAccount(name: "Player One", email: nil, photo: nil))
        XCTAssertEqual(target.accountHint, "Player One")
        target.take(
            BackupAccount(
                name: "Player One", email: "p@example.com",
                photo: URL(string: "https://example.com/p.jpg")))
        XCTAssertEqual(target.accountHint, "p@example.com")
        XCTAssertEqual(target.accountName, "Player One")
        XCTAssertEqual(target.accountPhoto, URL(string: "https://example.com/p.jpg"))
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

    func testATargetsFileThatDoesNotReadIsAnError() throws {
        // A folder at the file's path fails the read with an error
        // other than "no such file".
        try FileManager.default.createDirectory(
            at: BackupRootLayout(applicationSupport: tempRoot).targetsFile,
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try TargetDescriptorFile.read(applicationSupport: tempRoot))
    }

    func testADamagedTargetsFileKeepsACopyAndReadsAsAnEmptyOne() throws {
        let url = BackupRootLayout(applicationSupport: tempRoot).targetsFile
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{".utf8)
        try damaged.write(to: url)

        XCTAssertTrue(try TargetDescriptorFile.read(applicationSupport: tempRoot).targets.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(url.lastPathComponent + ".damaged-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(
                try XCTUnwrap(kept.first))),
            damaged)
    }

    func testEveryV1ProviderHasAName() {
        XCTAssertEqual(
            Set(BackupProviderKind.allCases.map(\.rawValue)),
            ["icloud-drive", "dropbox", "google-drive", "s3", "webdav"])
    }

    func testATargetOnAServiceThisBuildDoesNotKnowIsSkipped() throws {
        let file = Data(
            #"""
            {"version":1,"targets":[
            {"id":"a","provider":"sftp","label":"Old","root":"","isPaused":false},
            {"id":"b","provider":"dropbox","label":"Dropbox","root":"","isPaused":false}]}
            """#.utf8)

        let read = try TargetDescriptorFile.decode(json: file)

        XCTAssertEqual(read.targets.map(\.id), ["b"])
    }
}
