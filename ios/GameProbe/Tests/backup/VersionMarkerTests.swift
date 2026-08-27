import Foundation
import XCTest

@testable import GameProbe

/// The version marker of SPEC 4.4 and the one restore it warns
/// before.
final class VersionMarkerTests: XCTestCase {

    private var root: URL!
    private var gameDirectory: URL { root.appendingPathComponent("Game", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: BackupFixtures.url("container"), to: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func marker(jgp: String? = nil) -> SnapshotManifest.VersionMarker {
        VersionMarkerBuilder.make(gameDirectory: gameDirectory, jgpManifestVersion: jgp)
    }

    private func append(_ text: String, to path: String) throws {
        let url = gameDirectory.appendingPathComponent(path)
        let data = try Data(contentsOf: url) + Data(text.utf8)
        try data.write(to: url)
    }

    // MARK: - The three parts, per 4.4

    func testTheMarkerCarriesTheINIHashTheCountAndTheSize() throws {
        let marker = marker(jgp: "3")

        XCTAssertEqual(
            marker.gameINIHash,
            try ContentHash.hexOfFile(at: gameDirectory.appendingPathComponent("Game.ini")))
        XCTAssertEqual(marker.jgpManifestVersion, "3")
        XCTAssertEqual(marker.fileCount, 8)
        XCTAssertGreaterThan(marker.totalSize, 0)
    }

    func testAnUntouchedTreeKeepsOneMarker() {
        XCTAssertEqual(marker(), marker())
    }

    func testTheMarkerDiffersAfterTheINIBytesChange() throws {
        let before = marker()
        try append("\n; a self-update wrote this", to: "Game.ini")

        XCTAssertNotEqual(marker().gameINIHash, before.gameINIHash)
        XCTAssertNotEqual(marker(), before)
    }

    func testTheMarkerDiffersAfterTheFileCountChanges() throws {
        let before = marker()
        try Data("patch".utf8).write(
            to: gameDirectory.appendingPathComponent("Data/Patch.rxdata"))

        XCTAssertEqual(marker().fileCount, before.fileCount + 1)
        XCTAssertNotEqual(marker(), before)
    }

    func testTheMarkerDiffersAfterTheTreeSizeChanges() throws {
        let before = marker()
        try append("more save bytes", to: "Game.rxdata")

        XCTAssertEqual(marker().fileCount, before.fileCount)
        XCTAssertGreaterThan(marker().totalSize, before.totalSize)
        XCTAssertNotEqual(marker(), before)
    }

    func testAFileThatIsAlwaysOutDoesNotMoveTheMarker() throws {
        let before = marker()
        let fonts = gameDirectory.appendingPathComponent("Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("a font the user dropped in".utf8).write(
            to: fonts.appendingPathComponent("extra.ttf"))

        XCTAssertEqual(marker(), before)
    }

    func testAGameWithNoINIHasNoHash() throws {
        try FileManager.default.removeItem(at: gameDirectory.appendingPathComponent("Game.ini"))

        XCTAssertNil(marker().gameINIHash)
    }

    // MARK: - The one warning, per 4.4

    func testAFullModeRestoreOverADifferentTreeWarns() {
        let snapshot = SnapshotManifest.VersionMarker(fileCount: 12, totalSize: 900)
        let local = SnapshotManifest.VersionMarker(fileCount: 14, totalSize: 1200)

        XCTAssertTrue(
            VersionMarkerBuilder.warnsBeforeRestore(
                mode: .full, snapshot: snapshot, local: local))
    }

    func testARestoreOfSavesAndSettingsNeverWarns() {
        let snapshot = SnapshotManifest.VersionMarker(fileCount: 12, totalSize: 900)
        let local = SnapshotManifest.VersionMarker(fileCount: 14, totalSize: 1200)

        XCTAssertFalse(
            VersionMarkerBuilder.warnsBeforeRestore(
                mode: .slim, snapshot: snapshot, local: local))
    }

    func testAFullModeRestoreOverTheSameTreeDoesNotWarn() {
        let both = marker()

        XCTAssertFalse(
            VersionMarkerBuilder.warnsBeforeRestore(mode: .full, snapshot: both, local: both))
    }

    // MARK: - The marker is not identity, per 4.4

    func testAGameThatUpdatesItselfKeepsOneIdentity() throws {
        let game = GameIdentity(folderName: "Fixture Quest")
        let before = marker()
        try append("\n; the update", to: "Game.ini")

        XCTAssertNotEqual(marker(), before)
        XCTAssertTrue(
            GameIdentityMatch.matches(
                SnapshotIdentity(containerFolderName: "Fixture Quest"), game))
    }
}
