import Foundation
import XCTest

@testable import GameProbe

final class LegacyDataDrainTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("LegacyDataDrainTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? GameTreeUpdate.normalizeOwnerWritable(at: tempRoot)
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTree(_ name: String, files: [String: String]) throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func setMtime(_ root: URL, _ relativePath: String, _ epoch: TimeInterval) throws {
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: epoch)],
            ofItemAtPath: root.appendingPathComponent(relativePath).path)
    }

    /// Full recursive snapshot: relative path -> file content, or
    /// "<dir>" for directories. Comparing snapshots pins the WHOLE
    /// final tree, not just the entries a test remembered to check.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(atPath: root.path) else { return result }
        for case let relative as String in enumerator {
            let url = root.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                result[relative] = "<dir>"
            } else {
                result[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return result
    }

    // MARK: - Degenerate sources

    func testMissingSourceIsANoOpAndDoesNotCreateDestination() {
        let source = tempRoot.appendingPathComponent("gone", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome, LegacyDataDrain.Outcome())
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testFileSourceIsANoOpAndDoesNotCreateDestination() throws {
        let source = tempRoot.appendingPathComponent("UserData")
        try "not a directory".write(to: source, atomically: true, encoding: .utf8)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome, LegacyDataDrain.Outcome())
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "not a directory")
    }

    func testEmptySourceIsRemoved() throws {
        let source = try makeTree("UserData", files: [:])
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.removedSource)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try snapshot(destination), [:])
    }

    // MARK: - Plain moves

    func testDrainCreatesMissingDestination() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "save"])
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.removedSource)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: destination.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(try snapshot(destination), ["Game.rxdata": "save"])
    }

    func testPlainMoveTakesFilesAndSubdirectoriesWhole() throws {
        let source = try makeTree(
            "UserData",
            files: [
                "Game.rxdata": "save",
                "saves/slot1.rvdata2": "slot",
            ])
        let destination = try makeTree("dest", files: [:])

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 2)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.removedSource)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "save",
                "saves": "<dir>",
                "saves/slot1.rvdata2": "slot",
            ])
    }

    // MARK: - File conflicts

    func testNewerSourceWinsCanonicalNameAndArchivesDestination() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "new"])
        let destination = try makeTree("dest", files: ["Game.rxdata": "old"])
        try setMtime(source, "Game.rxdata", 200)
        try setMtime(destination, "Game.rxdata", 100)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(outcome.removedSource)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "new",
                "Game.rxdata.empo-displaced.bak": "old",
            ])
    }

    func testNewerDestinationKeepsCanonicalNameAndDisplacesSource() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "stale retry"])
        let destination = try makeTree("dest", files: ["Game.rxdata": "live"])
        try setMtime(source, "Game.rxdata", 100)
        try setMtime(destination, "Game.rxdata", 200)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(outcome.removedSource)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "live",
                "Game.rxdata.empo-displaced.bak": "stale retry",
            ])
    }

    func testEqualModificationTimesGoToTheIncomingFile() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "retry"])
        let destination = try makeTree("dest", files: ["Game.rxdata": "crashed"])
        try setMtime(source, "Game.rxdata", 150)
        try setMtime(destination, "Game.rxdata", 150)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.removedSource)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "retry",
                "Game.rxdata.empo-displaced.bak": "crashed",
            ])
    }

    func testIdenticalIncomingFileIsDroppedNotArchived() throws {
        // Identical bytes at the canonical name: archiving would
        // stack duplicate displaced copies on every repeat merge.
        let source = try makeTree("UserData", files: ["Game.rxdata": "same bytes"])
        let destination = try makeTree("dest", files: ["Game.rxdata": "same bytes"])
        try setMtime(source, "Game.rxdata", 300)
        try setMtime(destination, "Game.rxdata", 100)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(outcome.removedSource)
        XCTAssertEqual(try snapshot(destination), ["Game.rxdata": "same bytes"])
    }

    func testSameSizeDifferentContentIsStillArchived() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "AAAA"])
        let destination = try makeTree("dest", files: ["Game.rxdata": "BBBB"])
        try setMtime(source, "Game.rxdata", 200)
        try setMtime(destination, "Game.rxdata", 100)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "AAAA",
                "Game.rxdata.empo-displaced.bak": "BBBB",
            ])
    }

    func testSecondDrainNumbersTheSecondDisplacedCopy() throws {
        let destination = try makeTree("dest", files: ["Game.rxdata": "v1"])
        try setMtime(destination, "Game.rxdata", 100)

        let source1 = try makeTree("UserData1", files: ["Game.rxdata": "v2"])
        try setMtime(source1, "Game.rxdata", 200)
        LegacyDataDrain.drain(from: source1, into: destination)

        let source2 = try makeTree("UserData2", files: ["Game.rxdata": "v3"])
        try setMtime(source2, "Game.rxdata", 300)
        let outcome = LegacyDataDrain.drain(from: source2, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Game.rxdata": "v3",
                "Game.rxdata.empo-displaced.bak": "v1",
                "Game.rxdata.empo-displaced-2.bak": "v2",
            ])
    }

    // MARK: - Directory merges

    func testSameNamedDirectoriesMergeAndResolveInnerConflicts() throws {
        let source = try makeTree(
            "UserData",
            files: [
                "saves/Game.rxdata": "new save",
                "saves/extra.txt": "extra",
            ])
        let destination = try makeTree(
            "dest",
            files: [
                "saves/Game.rxdata": "old save",
                "saves/keep.txt": "keep",
            ])
        try setMtime(source, "saves/Game.rxdata", 200)
        try setMtime(destination, "saves/Game.rxdata", 100)

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 2)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.removedSource)
        // The emptied source subdirectory went away with the source.
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(
            try snapshot(destination),
            [
                "saves": "<dir>",
                "saves/Game.rxdata": "new save",
                "saves/Game.rxdata.empo-displaced.bak": "old save",
                "saves/extra.txt": "extra",
                "saves/keep.txt": "keep",
            ])
    }

    // MARK: - Type conflicts

    func testIncomingFileOverDirectoryIsDisplacedWhole() throws {
        let source = try makeTree("UserData", files: ["Audio": "now a file"])
        let destination = try makeTree("dest", files: ["Audio/bgm.ogg": "music"])

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(outcome.removedSource)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Audio": "<dir>",
                "Audio/bgm.ogg": "music",
                "Audio.empo-displaced.bak": "now a file",
            ])
    }

    func testIncomingDirectoryOverFileIsDisplacedWhole() throws {
        let source = try makeTree("UserData", files: ["Data/inner.txt": "nested"])
        let destination = try makeTree("dest", files: ["Data": "flat file"])

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(outcome.removedSource)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Data": "flat file",
                "Data.empo-displaced.bak": "<dir>",
                "Data.empo-displaced.bak/inner.txt": "nested",
            ])
    }

    // MARK: - Displaced-name shapes

    func testDisplacedNamesForExtensionlessAndMultiDotFiles() throws {
        let source = try makeTree(
            "UserData",
            files: [
                "Save": "new plain",
                "a.b.rxdata": "new dotted",
            ])
        let destination = try makeTree(
            "dest",
            files: [
                "Save": "old plain",
                "a.b.rxdata": "old dotted",
            ])
        for path in ["Save", "a.b.rxdata"] {
            try setMtime(source, path, 200)
            try setMtime(destination, path, 100)
        }

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.movedCount, 2)
        XCTAssertEqual(
            try snapshot(destination),
            [
                "Save": "new plain",
                "Save.empo-displaced.bak": "old plain",
                "a.b.rxdata": "new dotted",
                "a.b.rxdata.empo-displaced.bak": "old dotted",
            ])
    }

    func testDisplacedNameFormat() {
        XCTAssertEqual(
            LegacyDataDrain.displacedName(for: "Game.rxdata"),
            "Game.rxdata.empo-displaced.bak")
        XCTAssertEqual(
            LegacyDataDrain.displacedName(for: "Game.rxdata", index: 2),
            "Game.rxdata.empo-displaced-2.bak")
        XCTAssertEqual(
            LegacyDataDrain.displacedName(for: "Save", index: 3),
            "Save.empo-displaced-3.bak")
    }

    // MARK: - Failures

    func testUnreadableSourceSubdirectoryIsRecordedAndSourceStays() throws {
        let source = try makeTree(
            "UserData",
            files: [
                "aaa.txt": "a",
                "zzz.txt": "z",
            ])
        let locked = source.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        // The same-named destination directory forces the recursive
        // merge, which must LIST the locked source directory.
        let destination = try makeTree("dest", files: [:])
        try fm.createDirectory(
            at: destination.appendingPathComponent("locked", isDirectory: true),
            withIntermediateDirectories: true)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        if (try? fm.contentsOfDirectory(atPath: locked.path)) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            throw XCTSkip("0o000 directory is still readable; likely running as root")
        }

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.failures, ["locked"])
        XCTAssertEqual(outcome.movedCount, 2)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertFalse(outcome.removedSource)
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
        XCTAssertEqual(
            try snapshot(destination),
            [
                "aaa.txt": "a",
                "zzz.txt": "z",
                "locked": "<dir>",
            ])
    }

    func testDrainNestedFailureRecordsSlashSeparatedRelativePath() throws {
        // The destination pre-contains a/locked/ so the recursion
        // enters a/ and only then fails on listing the locked source
        // subdirectory - the failure path must carry the "/".
        let source = try makeTree("UserData", files: [:])
        let locked = source.appendingPathComponent("a/locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let destination = try makeTree("dest", files: [:])
        try fm.createDirectory(
            at: destination.appendingPathComponent("a/locked", isDirectory: true),
            withIntermediateDirectories: true)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        if (try? fm.contentsOfDirectory(atPath: locked.path)) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            throw XCTSkip("0o000 directory is still readable; likely running as root")
        }

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.failures, ["a/locked"])
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertFalse(outcome.removedSource)
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
    }

    func testUnreadableSourceRootRecordsDotFailure() throws {
        let source = try makeTree("UserData", files: ["Game.rxdata": "save"])
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        }
        if (try? fm.contentsOfDirectory(atPath: source.path)) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            throw XCTSkip("0o000 directory is still readable; likely running as root")
        }

        let outcome = LegacyDataDrain.drain(from: source, into: destination)

        XCTAssertEqual(outcome.failures, ["."])
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertFalse(outcome.removedSource)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try snapshot(destination), [:])
    }
}
