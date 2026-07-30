import Foundation
import XCTest

@testable import GameProbe

final class GameTreeUpdateTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("GameTreeUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Fixtures set read-only modes; restore owner-write so the
        // temp root always deletes cleanly.
        try? GameTreeUpdate.normalizeOwnerWritable(at: tempRoot)
        try? fm.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTree(_ name: String, files: [String: String]) throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        if files.isEmpty {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func contents(_ root: URL, _ relativePath: String) -> String? {
        try? String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - mergeMove

    func testMergeIntoMissingDestinationIsAPlainMove() throws {
        let source = try makeTree("source", files: ["Game.exe": "new"])
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Game.exe"), "new")
        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }

    func testMergeReplacesTopLevelFileDestination() throws {
        // The destination path itself exists but is a FILE (not a
        // directory): the new tree replaces it wholesale.
        let source = try makeTree("source", files: ["Game.exe": "new"])
        let destination = tempRoot.appendingPathComponent("dest")
        try "just a file".write(to: destination, atomically: true, encoding: .utf8)

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Game.exe"), "new")
    }

    func testMergeOverwritesSamePathFiles() throws {
        let source = try makeTree("source", files: ["Data/Scripts.rxdata": "v2"])
        let destination = try makeTree("dest", files: ["Data/Scripts.rxdata": "v1"])

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Data/Scripts.rxdata"), "v2")
    }

    func testMergeKeepsDestinationOnlyFiles() throws {
        let source = try makeTree("source", files: ["Game.exe": "v2"])
        let destination = try makeTree(
            "dest",
            files: [
                "Game.exe": "v1",
                "Save01.rxdata": "precious save",
                "Mods/patch.rb": "mod",
            ])

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Game.exe"), "v2")
        XCTAssertEqual(contents(destination, "Save01.rxdata"), "precious save")
        XCTAssertEqual(contents(destination, "Mods/patch.rb"), "mod")
    }

    func testMergeRecursesIntoSharedDirectories() throws {
        let source = try makeTree(
            "source",
            files: [
                "Data/Map001.rxdata": "new map",
                "Data/Map002.rxdata": "added map",
            ])
        let destination = try makeTree(
            "dest",
            files: [
                "Data/Map001.rxdata": "old map",
                "Data/SaveSlot.rxdata": "in-data save",
            ])

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Data/Map001.rxdata"), "new map")
        XCTAssertEqual(contents(destination, "Data/Map002.rxdata"), "added map")
        XCTAssertEqual(contents(destination, "Data/SaveSlot.rxdata"), "in-data save")
    }

    func testMergeTypeConflictResolvesToNewEntry() throws {
        // File replaces directory.
        let source1 = try makeTree("source1", files: ["Audio": "now a file"])
        let destination1 = try makeTree("dest1", files: ["Audio/bgm.ogg": "music"])
        try GameTreeUpdate.mergeMove(from: source1, into: destination1)
        XCTAssertEqual(contents(destination1, "Audio"), "now a file")

        // Directory replaces file.
        let source2 = try makeTree("source2", files: ["Data/inner.txt": "nested"])
        let destination2 = try makeTree("dest2", files: ["Data": "was a file"])
        try GameTreeUpdate.mergeMove(from: source2, into: destination2)
        XCTAssertEqual(contents(destination2, "Data/inner.txt"), "nested")
    }

    func testMergeRemovesSourceHusk() throws {
        let source = try makeTree("source", files: ["Data/Map001.rxdata": "new"])
        let destination = try makeTree("dest", files: ["Data/Map001.rxdata": "old"])

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }

    // MARK: - stageAndSwap

    func testStageAndSwapMergesAndCleansArtifacts() throws {
        let target = try makeTree(
            "container/Game",
            files: [
                "Game.exe": "v1",
                "Save01.rxdata": "precious save",
            ])
        let source = try makeTree("incoming", files: ["Game.exe": "v2"])

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Game.exe"), "v2")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")

        let parent = target.deletingLastPathComponent()
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    func testStageAndSwapOverwritesInsideReadOnlyDirectories() throws {
        // The overwrite unlinks the old file, which needs write
        // permission on the PARENT DIRECTORY (a read-only file in a
        // writable directory deletes fine) - so the fixture locks
        // the directory. Windows-origin archives commonly land like
        // this; without the staging tree's permission
        // normalization, the merge fails with EACCES.
        let target = try makeTree(
            "container/Game",
            files: [
                "Data/Scripts.rxdata": "v1",
                "Save01.rxdata": "precious save",
            ])
        try fm.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: target.appendingPathComponent("Data/Scripts.rxdata").path)
        try fm.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: target.appendingPathComponent("Data").path)
        let source = try makeTree("incoming", files: ["Data/Scripts.rxdata": "v2"])

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Data/Scripts.rxdata"), "v2")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
    }

    func testStageAndSwapRecoversFromCrashLeftoverArtifacts() throws {
        // A previous update that crashed mid-way leaves staging
        // and/or backup siblings behind. The next update must clear
        // them and succeed instead of failing on the copy into an
        // already-existing staging path.
        let target = try makeTree("container/Game", files: ["Game.exe": "v1"])
        let parent = target.deletingLastPathComponent()
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "stale half-merged"])
        _ = try makeTree(
            "container/\(GameTreeUpdate.backupDirectoryName)",
            files: ["Game.exe": "stale backup"])
        let source = try makeTree("incoming", files: ["Game.exe": "v2"])

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Game.exe"), "v2")
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    func testStageAndSwapFailureLeavesTargetUntouched() throws {
        let target = try makeTree(
            "container/Game",
            files: [
                "Game.exe": "v1",
                "Save01.rxdata": "precious save",
            ])
        let missingSource = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        XCTAssertThrowsError(
            try GameTreeUpdate.stageAndSwap(newTree: missingSource, over: target))

        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")

        let parent = target.deletingLastPathComponent()
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    // MARK: - sweepInterruptedUpdate

    func testSweepRestoresMergedTreeWhenSwapDiedBetweenRenames() throws {
        // replaceItemAt = rename target->backup, rename
        // staging->target, delete backup. A kill between the
        // renames leaves NO target; the staging tree (fully merged)
        // must be restored, never swept.
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        let target = parent.appendingPathComponent("Game", isDirectory: true)
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "v2 merged", "Save01.rxdata": "precious save"])
        _ = try makeTree(
            "container/\(GameTreeUpdate.backupDirectoryName)",
            files: ["Game.exe": "v1", "Save01.rxdata": "precious save"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome.restoredFrom, GameTreeUpdate.stagingDirectoryName)
        XCTAssertEqual(outcome.removed, [GameTreeUpdate.backupDirectoryName])
        XCTAssertEqual(contents(target, "Game.exe"), "v2 merged")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
    }

    func testSweepFallsBackToBackupWhenStagingIsGone() throws {
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        let target = parent.appendingPathComponent("Game", isDirectory: true)
        _ = try makeTree(
            "container/\(GameTreeUpdate.backupDirectoryName)",
            files: ["Game.exe": "v1", "Save01.rxdata": "precious save"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome.restoredFrom, GameTreeUpdate.backupDirectoryName)
        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
    }

    func testSweepWithHealthyTargetOnlyRemovesLeftovers() throws {
        let target = try makeTree("container/Game", files: ["Game.exe": "live"])
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "stale"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertNil(outcome.restoredFrom)
        XCTAssertEqual(outcome.removed, [GameTreeUpdate.stagingDirectoryName])
        XCTAssertEqual(contents(target, "Game.exe"), "live")
    }

    func testSweepWithNothingToDoIsANoOp() throws {
        let target = try makeTree("container/Game", files: ["Game.exe": "live"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome, GameTreeUpdate.SweepOutcome(restoredFrom: nil, removed: []))
        XCTAssertEqual(contents(target, "Game.exe"), "live")
    }

    // MARK: - removeStaleArtifacts

    func testRemoveStaleArtifactsSweepsBothNamesAndReportsThem() throws {
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        for name in [GameTreeUpdate.stagingDirectoryName, GameTreeUpdate.backupDirectoryName] {
            try fm.createDirectory(
                at: parent.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let removed = GameTreeUpdate.removeStaleArtifacts(in: parent)

        XCTAssertEqual(
            Set(removed),
            [GameTreeUpdate.stagingDirectoryName, GameTreeUpdate.backupDirectoryName])
        XCTAssertEqual(GameTreeUpdate.removeStaleArtifacts(in: parent), [])
    }

    // MARK: - normalizeOwnerWritable

    func testNormalizeOwnerWritableRestoresPermissions() throws {
        let root = try makeTree("locked", files: ["Data/file.txt": "x"])
        try fm.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: root.appendingPathComponent("Data/file.txt").path)
        try fm.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: root.appendingPathComponent("Data").path)

        try GameTreeUpdate.normalizeOwnerWritable(at: root)

        let filePermissions =
            try fm.attributesOfItem(
                atPath: root.appendingPathComponent("Data/file.txt").path)[.posixPermissions]
            as? Int
        let dirPermissions =
            try fm.attributesOfItem(
                atPath: root.appendingPathComponent("Data").path)[.posixPermissions]
            as? Int
        XCTAssertEqual(filePermissions, 0o644)
        XCTAssertEqual(dirPermissions, 0o755)
    }
}
