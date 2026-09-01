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

    private var layout: BackupRootLayout { BackupRootLayout(applicationSupport: tempRoot) }

    func testTheRootHoldsTheDatabaseAndTheThreeDirectories() {
        XCTAssertEqual(layout.root.lastPathComponent, "Backup")
        XCTAssertEqual(layout.stateDatabase.lastPathComponent, "state.sqlite")
        XCTAssertEqual(layout.staging.lastPathComponent, "staging")
        XCTAssertEqual(layout.outbox.lastPathComponent, "outbox")
        XCTAssertEqual(layout.restore.lastPathComponent, "restore")
    }

    func testTheLayoutOfARootMatchesTheLayoutOfItsApplicationSupport() {
        XCTAssertEqual(BackupRootLayout(root: layout.root), layout)
    }

    func testADownloadedBlobIsKeyedByItsHash() {
        let hash = ContentHash.hex(ofUTF8: "save bytes")

        let url = layout.restoreBlob(hash: hash)

        XCTAssertEqual(url.lastPathComponent, hash)
        XCTAssertEqual(url.deletingLastPathComponent(), layout.restore)
    }

    func testTheTwoFilesSitBesideTheRootAndNotUnderIt() {
        // Empo may delete the root whole, per 6.1.
        let targets = layout.targetsFile
        let undo = layout.preferenceRollbackFile

        XCTAssertEqual(targets.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertEqual(undo.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertNotEqual(targets.deletingLastPathComponent().path, layout.root.path)
        XCTAssertNotEqual(undo.deletingLastPathComponent().path, layout.root.path)
    }

    func testCreateDirectoriesMakesAllFourAndRunsTwice() throws {
        try layout.createDirectories()
        try layout.createDirectories()

        let manager = FileManager.default
        for url in [layout.root, layout.staging, layout.outbox, layout.restore] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                "missing: \(url.lastPathComponent)")
            XCTAssertTrue(isDirectory.boolValue, "not a directory: \(url.lastPathComponent)")
        }
    }
}
