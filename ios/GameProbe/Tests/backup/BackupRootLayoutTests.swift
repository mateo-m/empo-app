import Foundation
import XCTest

@testable import GameProbe

/// The local root of SPEC 6.1.
final class BackupRootLayoutTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRootLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testTheRootHoldsTheDatabaseAndTheThreeDirectories() {
        let root = BackupRootLayout.root(inApplicationSupport: tempRoot)

        XCTAssertEqual(root.lastPathComponent, "Backup")
        XCTAssertEqual(
            BackupRootLayout.stateDatabase(root: root).lastPathComponent, "state.sqlite")
        XCTAssertEqual(BackupRootLayout.staging(root: root).lastPathComponent, "staging")
        XCTAssertEqual(BackupRootLayout.outbox(root: root).lastPathComponent, "outbox")
        XCTAssertEqual(BackupRootLayout.restore(root: root).lastPathComponent, "restore")
    }

    func testADownloadedBlobIsKeyedByItsHash() {
        let root = BackupRootLayout.root(inApplicationSupport: tempRoot)
        let hash = ContentHash.hex(ofUTF8: "save bytes")

        let url = BackupRootLayout.restoreBlob(root: root, hash: hash)

        XCTAssertEqual(url.lastPathComponent, hash)
        XCTAssertEqual(url.deletingLastPathComponent(), BackupRootLayout.restore(root: root))
    }

    func testTheTwoFilesSitBesideTheRootAndNotUnderIt() {
        // Empo may delete the root whole, per 6.1.
        let root = BackupRootLayout.root(inApplicationSupport: tempRoot)
        let targets = BackupRootLayout.targetsFile(applicationSupport: tempRoot)
        let undo = BackupRootLayout.preferenceRollbackFile(applicationSupport: tempRoot)

        XCTAssertEqual(targets.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertEqual(undo.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertNotEqual(targets.deletingLastPathComponent().path, root.path)
        XCTAssertNotEqual(undo.deletingLastPathComponent().path, root.path)
    }

    func testCreateDirectoriesMakesAllFourAndRunsTwice() throws {
        let root = BackupRootLayout.root(inApplicationSupport: tempRoot)

        try BackupRootLayout.createDirectories(root: root)
        try BackupRootLayout.createDirectories(root: root)

        let manager = FileManager.default
        for url in [
            root, BackupRootLayout.staging(root: root),
            BackupRootLayout.outbox(root: root), BackupRootLayout.restore(root: root),
        ] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                "missing: \(url.lastPathComponent)")
            XCTAssertTrue(isDirectory.boolValue, "not a directory: \(url.lastPathComponent)")
        }
    }
}
