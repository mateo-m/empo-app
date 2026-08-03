import Foundation
import XCTest

@testable import GameProbe

final class ConcatenatedSaveRecoveryTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent(
                "ConcatenatedSaveRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - remainder

    func testRemainderStripsThePrefixFromSaveNames() {
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataGame.rxdata"),
            "Game.rxdata")
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataSave01.rvdata"),
            "Save01.rvdata")
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataSave01.rvdata2"),
            "Save01.rvdata2")
    }

    func testRemainderAcceptsBakWrappedSaveNames() {
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataGame.rxdata.bak"),
            "Game.rxdata.bak")
        // The .bak unwrap is recursive.
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataGame.rvdata2.bak.bak"),
            "Game.rvdata2.bak.bak")
    }

    func testRemainderAcceptsUppercaseExtensions() {
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataGame.RXDATA"),
            "Game.RXDATA")
    }

    func testRemainderRejectsNonArtifacts() {
        XCTAssertNil(ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserData"))
        // A leading-dot remainder would recover into a hidden file.
        XCTAssertNil(ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserData.rxdata"))
        XCTAssertNil(ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDatareadme.txt"))
        // The prefix match is case-sensitive.
        XCTAssertNil(ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "userdataGame.rxdata"))
        XCTAssertNil(ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "Game.rxdata"))
    }

    func testRemainderStripsThePrefixOnce() {
        // A doubled prefix loses ONE layer per recovery pass; the
        // strip must not loop.
        XCTAssertEqual(
            ConcatenatedSaveRecovery.remainder(ofConcatenatedName: "UserDataUserDataGame.rxdata"),
            "UserDataGame.rxdata")
    }

    // MARK: - backupName

    func testBackupNameFormat() {
        XCTAssertEqual(
            ConcatenatedSaveRecovery.backupName(for: "Game.rxdata"),
            "Game.rxdata.empo-path-regression.bak")
        XCTAssertEqual(
            ConcatenatedSaveRecovery.backupName(for: "Game.rxdata", index: 2),
            "Game.rxdata.empo-path-regression-2.bak")
    }

    // MARK: - merge helpers

    /// The merge crosses directories in production: the artifact
    /// sits at the container ROOT, the canonical save in the SHARED
    /// data directory. The fixtures mirror that split so a backup
    /// landing beside the SOURCE (instead of beside the canonical)
    /// fails the full-directory assertions.
    private func makeFile(_ relative: String, _ content: String, mtime: TimeInterval? = nil)
        throws -> URL
    {
        let url = tempRoot.appendingPathComponent(relative)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: mtime)],
                ofItemAtPath: url.path)
        }
        return url
    }

    private func directoryContents(_ name: String) throws -> [String: String] {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        var result: [String: String] = [:]
        for entry in try fm.contentsOfDirectory(atPath: dir.path) {
            result[entry] = try String(
                contentsOf: dir.appendingPathComponent(entry), encoding: .utf8)
        }
        return result
    }

    // MARK: - merge

    func testMergeWithoutCanonicalIsAPlainMove() throws {
        let source = try makeFile("root/UserDataGame.rxdata", "recovered")
        let shared = tempRoot.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let canonical = shared.appendingPathComponent("Game.rxdata")

        try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical)

        XCTAssertEqual(try directoryContents("root"), [:])
        XCTAssertEqual(try directoryContents("shared"), ["Game.rxdata": "recovered"])
    }

    func testMergeNewerSourceWinsAndOldCanonicalIsBackedUp() throws {
        let source = try makeFile("root/UserDataGame.rxdata", "new", mtime: 200)
        let canonical = try makeFile("shared/Game.rxdata", "old", mtime: 100)

        try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical)

        XCTAssertEqual(try directoryContents("root"), [:])
        XCTAssertEqual(
            try directoryContents("shared"),
            [
                "Game.rxdata": "new",
                "Game.rxdata.empo-path-regression.bak": "old",
            ])
    }

    func testMergeNewerCanonicalStaysAndSourceIsBackedUp() throws {
        let source = try makeFile("root/UserDataGame.rxdata", "stale", mtime: 100)
        let canonical = try makeFile("shared/Game.rxdata", "live", mtime: 200)

        try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical)

        XCTAssertEqual(try directoryContents("root"), [:])
        XCTAssertEqual(
            try directoryContents("shared"),
            [
                "Game.rxdata": "live",
                "Game.rxdata.empo-path-regression.bak": "stale",
            ])
    }

    func testMergeEqualModificationTimesGoToTheSource() throws {
        let source = try makeFile("root/UserDataGame.rxdata", "retry", mtime: 150)
        let canonical = try makeFile("shared/Game.rxdata", "crashed", mtime: 150)

        try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical)

        XCTAssertEqual(try directoryContents("root"), [:])
        XCTAssertEqual(
            try directoryContents("shared"),
            [
                "Game.rxdata": "retry",
                "Game.rxdata.empo-path-regression.bak": "crashed",
            ])
    }

    func testMergeNumbersTheSecondBackup() throws {
        _ = try makeFile("shared/Game.rxdata.empo-path-regression.bak", "first backup")
        let source = try makeFile("root/UserDataGame.rxdata", "newest", mtime: 300)
        let canonical = try makeFile("shared/Game.rxdata", "middle", mtime: 200)

        try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical)

        XCTAssertEqual(try directoryContents("root"), [:])
        XCTAssertEqual(
            try directoryContents("shared"),
            [
                "Game.rxdata": "newest",
                "Game.rxdata.empo-path-regression.bak": "first backup",
                "Game.rxdata.empo-path-regression-2.bak": "middle",
            ])
    }
}
