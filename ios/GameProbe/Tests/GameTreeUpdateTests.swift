import Foundation
import XCTest

@testable import GameProbe

/// Seam for the swap-failure tests: intercepts the replace call
/// `stageAndSwap` makes through the injected `fm`.
///
/// On Darwin, `FileManager.replaceItemAt` is a Swift overlay
/// convenience that forwards to the Objective-C
/// `replaceItem(at:withItemAt:backupItemName:options:resultingItemURL:)`,
/// which dispatches dynamically - so overriding it here intercepts
/// the swap. On corelibs Foundation both entry points are `public`
/// (not `open`) and forward to an internal `_replaceItem`, so a
/// subclass cannot intercept them; the tests detect that at runtime
/// via `swapIntercepted` and skip.
private final class SwapInterceptingFileManager: FileManager {
    /// Called with (target, staging) before the real replace; throw
    /// to simulate a failed swap.
    var onSwap: ((URL, URL) throws -> Void)?
    private(set) var swapIntercepted = false

    #if canImport(Darwin)
    override func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        swapIntercepted = true
        try onSwap?(originalItemURL, newItemURL)
        try super.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options,
            resultingItemURL: resultingItemURL)
    }
    #endif
}

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
        // The whole source moved, so no husk remains.
        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }

    func testMergeZeroByteSourceFileOverwritesNonEmptyDestinationFile() throws {
        let source = try makeTree("source", files: ["Data/Scripts.rxdata": ""])
        let destination = try makeTree("dest", files: ["Data/Scripts.rxdata": "old bytes"])

        try GameTreeUpdate.mergeMove(from: source, into: destination)

        XCTAssertEqual(contents(destination, "Data/Scripts.rxdata"), "")
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

    // MARK: - Protected save collisions

    private func setModificationDate(_ root: URL, _ relativePath: String, _ date: Date) throws {
        try fm.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: root.appendingPathComponent(relativePath).path)
    }

    private func displaced(_ name: String) -> String {
        LegacyDataDrain.displacedName(for: name)
    }

    func testProtectedCollisionKeepsTheNewerInstalledSave() throws {
        let source = try makeTree("source", files: ["Save A.rxdata": "archive junk"])
        let destination = try makeTree("dest", files: ["Save A.rxdata": "player save"])
        try setModificationDate(source, "Save A.rxdata", Date(timeIntervalSince1970: 1000))
        try setModificationDate(destination, "Save A.rxdata", Date(timeIntervalSince1970: 2000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "player save")
        XCTAssertEqual(contents(destination, displaced("Save A.rxdata")), "archive junk")
    }

    func testProtectedCollisionLetsANewerIncomingSaveWinThePath() throws {
        let source = try makeTree("source", files: ["Save A.rxdata": "transferred save"])
        let destination = try makeTree("dest", files: ["Save A.rxdata": "stale save"])
        try setModificationDate(source, "Save A.rxdata", Date(timeIntervalSince1970: 2000))
        try setModificationDate(destination, "Save A.rxdata", Date(timeIntervalSince1970: 1000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "transferred save")
        XCTAssertEqual(contents(destination, displaced("Save A.rxdata")), "stale save")
    }

    func testProtectedCollisionTieGoesToTheIncomingFile() throws {
        let source = try makeTree("source", files: ["Save A.rxdata": "incoming"])
        let destination = try makeTree("dest", files: ["Save A.rxdata": "installed"])
        let date = Date(timeIntervalSince1970: 1500)
        try setModificationDate(source, "Save A.rxdata", date)
        try setModificationDate(destination, "Save A.rxdata", date)

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "incoming")
        XCTAssertEqual(contents(destination, displaced("Save A.rxdata")), "installed")
    }

    func testProtectedCollisionNeverDeletesEitherCopy() throws {
        // A second collision on the same name takes the numbered
        // marker instead of overwriting the first displaced copy.
        let source = try makeTree("source", files: ["Save A.rxdata": "second archive"])
        let destination = try makeTree(
            "dest",
            files: [
                "Save A.rxdata": "player save",
                displaced("Save A.rxdata"): "first archive",
            ])
        try setModificationDate(source, "Save A.rxdata", Date(timeIntervalSince1970: 1000))
        try setModificationDate(destination, "Save A.rxdata", Date(timeIntervalSince1970: 2000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "player save")
        XCTAssertEqual(contents(destination, displaced("Save A.rxdata")), "first archive")
        XCTAssertEqual(
            contents(destination, LegacyDataDrain.displacedName(for: "Save A.rxdata", index: 2)),
            "second archive")
    }

    func testProtectedCollisionWithIdenticalBytesLeavesNoDisplacedCopy() throws {
        // An update that re-ships the exact same save bytes must
        // not stack a duplicate .bak on every install.
        let source = try makeTree("source", files: ["Save A.rxdata": "same bytes"])
        let destination = try makeTree("dest", files: ["Save A.rxdata": "same bytes"])
        try setModificationDate(source, "Save A.rxdata", Date(timeIntervalSince1970: 2000))
        try setModificationDate(destination, "Save A.rxdata", Date(timeIntervalSince1970: 1000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "same bytes")
        XCTAssertFalse(
            fm.fileExists(
                atPath: destination.appendingPathComponent(displaced("Save A.rxdata")).path))
    }

    func testProtectedNamesMatchCaseInsensitively() throws {
        let source = try makeTree("source", files: ["Save A.rxdata": "archive junk"])
        let destination = try makeTree("dest", files: ["Save A.rxdata": "player save"])
        try setModificationDate(source, "Save A.rxdata", Date(timeIntervalSince1970: 1000))
        try setModificationDate(destination, "Save A.rxdata", Date(timeIntervalSince1970: 2000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["SAVE A.RXDATA"])

        XCTAssertEqual(contents(destination, "Save A.rxdata"), "player save")
        XCTAssertEqual(contents(destination, displaced("Save A.rxdata")), "archive junk")
    }

    func testProtectedDirectoryMergesPerFile() throws {
        let source = try makeTree(
            "source",
            files: [
                "save/slot1.rxdata": "archive slot1",
                "save/slot2.rxdata": "new slot2",
            ])
        let destination = try makeTree("dest", files: ["save/slot1.rxdata": "player slot1"])
        try setModificationDate(source, "save/slot1.rxdata", Date(timeIntervalSince1970: 1000))
        try setModificationDate(
            destination, "save/slot1.rxdata", Date(timeIntervalSince1970: 2000))

        try GameTreeUpdate.mergeMove(from: source, into: destination, protecting: ["save"])

        XCTAssertEqual(contents(destination, "save/slot1.rxdata"), "player slot1")
        XCTAssertEqual(contents(destination, "save/" + displaced("slot1.rxdata")), "archive slot1")
        XCTAssertEqual(contents(destination, "save/slot2.rxdata"), "new slot2")
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent("save").path))
    }

    func testProtectedTypeConflictKeepsTheInstalledEntry() throws {
        let source = try makeTree("source", files: ["save": "a file named save"])
        let destination = try makeTree("dest", files: ["save/slot1.rxdata": "player slot1"])

        try GameTreeUpdate.mergeMove(from: source, into: destination, protecting: ["save"])

        XCTAssertEqual(contents(destination, "save/slot1.rxdata"), "player slot1")
        XCTAssertEqual(contents(destination, displaced("save")), "a file named save")
    }

    func testUnprotectedCollisionStillOverwritesInPlace() throws {
        let source = try makeTree("source", files: ["notes.txt": "new"])
        let destination = try makeTree("dest", files: ["notes.txt": "old"])
        try setModificationDate(source, "notes.txt", Date(timeIntervalSince1970: 1000))
        try setModificationDate(destination, "notes.txt", Date(timeIntervalSince1970: 2000))

        try GameTreeUpdate.mergeMove(
            from: source, into: destination, protecting: ["Save A.rxdata"])

        XCTAssertEqual(contents(destination, "notes.txt"), "new")
        XCTAssertFalse(
            fm.fileExists(
                atPath: destination.appendingPathComponent(displaced("notes.txt")).path))
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

    func testStageAndSwapProtectsCollidingPortableSaves() throws {
        // The archive ships a file at the installed save's path (a
        // repack with the packer's own save). The swap must keep
        // the player's copy on the save path and archive the
        // incoming copy beside it - and still overwrite plain game
        // files.
        let target = try makeTree(
            "container/Game",
            files: [
                "Game.exe": "v1",
                "Save01.rxdata": "player save",
            ])
        let source = try makeTree(
            "incoming",
            files: [
                "Game.exe": "v2",
                "Save01.rxdata": "packer save",
            ])
        // Far in the past: even a staging copy that refreshes
        // modification dates leaves the installed copy newer.
        try setModificationDate(source, "Save01.rxdata", Date(timeIntervalSince1970: 0))

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Game.exe"), "v2")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "player save")
        XCTAssertEqual(contents(target, displaced("Save01.rxdata")), "packer save")
    }

    func testStageAndSwapLandsADeliberateSaveTransfer() throws {
        // The opposite direction: the user packed a fresher save
        // into the archive on purpose. The newer incoming copy
        // wins the save path; the stale installed copy survives
        // beside it.
        let target = try makeTree("container/Game", files: ["Save01.rxdata": "stale save"])
        let source = try makeTree("incoming", files: ["Save01.rxdata": "fresh save"])
        try setModificationDate(
            source, "Save01.rxdata", Date(timeIntervalSinceNow: 365 * 24 * 3600))

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Save01.rxdata"), "fresh save")
        XCTAssertEqual(contents(target, displaced("Save01.rxdata")), "stale save")
    }

    func testStageAndSwapProtectsMarshalMagicFilesWhateverTheirName() throws {
        // A root file without a save extension counts when its
        // first bytes are the Marshal magic - localized or renamed
        // saves must get the same protection.
        let target = try makeTree(
            "container/Game", files: ["profil du joueur": "\u{04}\u{08}player"])
        let source = try makeTree(
            "incoming", files: ["profil du joueur": "\u{04}\u{08}packer"])
        try setModificationDate(source, "profil du joueur", Date(timeIntervalSince1970: 0))

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "profil du joueur"), "\u{04}\u{08}player")
        XCTAssertEqual(contents(target, displaced("profil du joueur")), "\u{04}\u{08}packer")
    }

    func testStageAndSwapStillOverwritesEngineDataFiles() throws {
        // Data/ is an engine directory: its Marshal files are game
        // assets, and an update must replace them without leaving
        // displaced copies behind.
        let target = try makeTree(
            "container/Game", files: ["Data/Scripts.rxdata": "\u{04}\u{08}v1"])
        let source = try makeTree(
            "incoming", files: ["Data/Scripts.rxdata": "\u{04}\u{08}v2"])
        try setModificationDate(source, "Data/Scripts.rxdata", Date(timeIntervalSince1970: 0))

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "Data/Scripts.rxdata"), "\u{04}\u{08}v2")
        XCTAssertFalse(
            fm.fileExists(
                atPath: target.appendingPathComponent("Data/" + displaced("Scripts.rxdata")).path))
    }

    func testStageAndSwapProtectsSaveFoldersAutomatically() throws {
        let target = try makeTree(
            "container/Game", files: ["save/slot1.rxdata": "player slot1"])
        let source = try makeTree(
            "incoming",
            files: [
                "save/slot1.rxdata": "packer slot1",
                "save/slot2.rxdata": "new slot2",
            ])
        try setModificationDate(source, "save/slot1.rxdata", Date(timeIntervalSince1970: 0))

        try GameTreeUpdate.stageAndSwap(newTree: source, over: target)

        XCTAssertEqual(contents(target, "save/slot1.rxdata"), "player slot1")
        XCTAssertEqual(contents(target, "save/" + displaced("slot1.rxdata")), "packer slot1")
        XCTAssertEqual(contents(target, "save/slot2.rxdata"), "new slot2")
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

    func testStageAndSwapMidMergeFailureLeavesTargetUntouched() throws {
        // An unreadable source subdirectory makes the merge throw
        // after the staging copy exists. The failure path must leave
        // the target byte-identical; the target is healthy, so the
        // artifacts are swept.
        let target = try makeTree(
            "container/Game",
            files: [
                "Game.exe": "v1",
                "locked/data.txt": "orig",
            ])
        let source = try makeTree(
            "incoming",
            files: [
                "Game.exe": "v2",
                "locked/data.txt": "new",
            ])
        let lockedSource = source.appendingPathComponent("locked", isDirectory: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSource.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSource.path)
        }
        if (try? fm.contentsOfDirectory(atPath: lockedSource.path)) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            throw XCTSkip("0o000 directory is still readable; likely running as root")
        }

        XCTAssertThrowsError(try GameTreeUpdate.stageAndSwap(newTree: source, over: target))

        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "locked/data.txt"), "orig")
        let parent = target.deletingLastPathComponent()
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    // MARK: - stageAndSwap failure during the swap itself

    /// Standard fixture for the swap-failure tests: an installed v1
    /// tree with a save, and an incoming v2 tree.
    private func makeSwapFixture() throws -> (target: URL, source: URL, parent: URL) {
        let target = try makeTree(
            "container/Game",
            files: [
                "Game.exe": "v1",
                "Save01.rxdata": "precious save",
            ])
        let source = try makeTree("incoming", files: ["Game.exe": "v2"])
        return (target, source, target.deletingLastPathComponent())
    }

    /// Runs `stageAndSwap` through the intercepting FileManager and
    /// returns the thrown error. Skips the test when the platform
    /// offers no override seam (corelibs `replaceItemAt` is not
    /// `open`); in that case the real swap ran and succeeded, so
    /// nothing below the skip would hold.
    private func runFailingSwap(
        _ swapFM: SwapInterceptingFileManager, source: URL, target: URL
    ) throws -> NSError {
        var thrown: NSError?
        do {
            try GameTreeUpdate.stageAndSwap(newTree: source, over: target, fm: swapFM)
        } catch {
            thrown = error as NSError
        }
        guard swapFM.swapIntercepted else {
            throw XCTSkip(
                "FileManager subclasses cannot intercept replaceItemAt on this platform")
        }
        let error = try XCTUnwrap(thrown, "the intercepted swap must rethrow")
        return error
    }

    func testFailedSwapRestoresTheDisplacedOriginalFromAURLKey() throws {
        // Foundation documents that a failed replace may strand the
        // original at a temporary location, recorded under
        // NSFileOriginalItemLocationKey. The failure path must move
        // it home.
        let (target, source, parent) = try makeSwapFixture()
        let displaced = parent.appendingPathComponent("displaced-original", isDirectory: true)
        let swapFM = SwapInterceptingFileManager()
        swapFM.onSwap = { swapTarget, _ in
            try FileManager.default.moveItem(at: swapTarget, to: displaced)
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: ["NSFileOriginalItemLocationKey": displaced])
        }

        let error = try runFailingSwap(swapFM, source: source, target: target)

        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, CocoaError.fileWriteUnknown.rawValue)
        // The pre-update tree is back at the target, byte-for-byte.
        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
        // The displaced copy moved home; the artifacts are swept.
        XCTAssertFalse(fm.fileExists(atPath: displaced.path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    func testFailedSwapRestoresTheDisplacedOriginalFromAStringKey() throws {
        // Some Foundation implementations store the displaced
        // location as a path String instead of a URL.
        let (target, source, parent) = try makeSwapFixture()
        let displaced = parent.appendingPathComponent("displaced-original", isDirectory: true)
        let swapFM = SwapInterceptingFileManager()
        swapFM.onSwap = { swapTarget, _ in
            try FileManager.default.moveItem(at: swapTarget, to: displaced)
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: ["NSFileOriginalItemLocationKey": displaced.path])
        }

        _ = try runFailingSwap(swapFM, source: source, target: target)

        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
        XCTAssertFalse(fm.fileExists(atPath: displaced.path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.backupDirectoryName).path))
    }

    func testFailedSwapWithoutLocationKeyPrefersTheBackupTree() throws {
        // No displaced-location key, both artifacts on disk: the
        // in-flight failure path restores the BACKUP (the pre-update
        // tree). Promoting the merged staging tree would install the
        // new files behind a failure report. Once the target is
        // healthy again, the staging tree is removed.
        let (target, source, parent) = try makeSwapFixture()
        let backup = parent.appendingPathComponent(
            GameTreeUpdate.backupDirectoryName, isDirectory: true)
        let swapFM = SwapInterceptingFileManager()
        swapFM.onSwap = { swapTarget, _ in
            // Simulate a replace that died after displacing the
            // original into the named backup slot.
            try FileManager.default.moveItem(at: swapTarget, to: backup)
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue)
        }

        _ = try runFailingSwap(swapFM, source: source, target: target)

        // The target holds the backup content: the pre-update tree,
        // not the merged one.
        XCTAssertEqual(contents(target, "Game.exe"), "v1")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
        // Both artifacts are gone: the backup became the target and
        // the redundant staging tree was removed.
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: parent.appendingPathComponent(GameTreeUpdate.stagingDirectoryName).path))
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

    func testSweepWithHealthyTargetRemovesBothArtifactsInOrder() throws {
        let target = try makeTree("container/Game", files: ["Game.exe": "live"])
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "stale staging"])
        _ = try makeTree(
            "container/\(GameTreeUpdate.backupDirectoryName)",
            files: ["Game.exe": "stale backup"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertNil(outcome.restoredFrom)
        XCTAssertEqual(
            outcome.removed,
            [GameTreeUpdate.stagingDirectoryName, GameTreeUpdate.backupDirectoryName])
        XCTAssertEqual(contents(target, "Game.exe"), "live")
    }

    func testSweepRestoresFromStagingOnlyWhenTargetMissing() throws {
        // After the restore consumes the staging tree, no artifact
        // remains, so removed stays empty.
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        let target = parent.appendingPathComponent("Game", isDirectory: true)
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "v2 merged", "Save01.rxdata": "precious save"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome.restoredFrom, GameTreeUpdate.stagingDirectoryName)
        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(contents(target, "Game.exe"), "v2 merged")
        XCTAssertEqual(contents(target, "Save01.rxdata"), "precious save")
    }

    func testSweepMovesStrayFileAsideAndRestoresFromStaging() throws {
        // A stray FILE at the target path does not count as a
        // healthy tree. With an artifact available, the file moves
        // aside and the restore proceeds.
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Game", isDirectory: true)
        try "crash artifact".write(
            to: parent.appendingPathComponent("Game"), atomically: true, encoding: .utf8)
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "v2 merged"])

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome.restoredFrom, GameTreeUpdate.stagingDirectoryName)
        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(contents(target, "Game.exe"), "v2 merged")
        XCTAssertEqual(
            try String(
                contentsOf: parent.appendingPathComponent("Game.empo-unexpected"),
                encoding: .utf8),
            "crash artifact")
    }

    func testSweepLeavesStrayFileAloneWhenNoArtifactsExist() throws {
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let strayFile = parent.appendingPathComponent("Game")
        try "not a tree".write(to: strayFile, atomically: true, encoding: .utf8)
        let target = parent.appendingPathComponent("Game", isDirectory: true)

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome, GameTreeUpdate.SweepOutcome(restoredFrom: nil, removed: []))
        XCTAssertEqual(try String(contentsOf: strayFile, encoding: .utf8), "not a tree")
        XCTAssertFalse(
            fm.fileExists(atPath: parent.appendingPathComponent("Game.empo-unexpected").path))
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

    func testSweepReturnsEmptyRemovedWhenRestoreFails() throws {
        // A read-only parent makes the restore move fail. The sweep
        // must then report nothing removed and leave the staging
        // artifact on disk for the next attempt.
        _ = try makeTree(
            "container/\(GameTreeUpdate.stagingDirectoryName)",
            files: ["Game.exe": "v2 merged"])
        let parent = tempRoot.appendingPathComponent("container", isDirectory: true)
        let target = parent.appendingPathComponent("Game", isDirectory: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }
        let probe = parent.appendingPathComponent("write-probe")
        if (try? Data().write(to: probe)) != nil {
            // Root ignores POSIX permission bits (CI containers can
            // run as root), so the failure cannot be provoked.
            try? fm.removeItem(at: probe)
            throw XCTSkip("0o555 directory is still writable; likely running as root")
        }

        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: target)

        XCTAssertEqual(outcome, GameTreeUpdate.SweepOutcome(restoredFrom: nil, removed: []))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertEqual(
            contents(parent, "\(GameTreeUpdate.stagingDirectoryName)/Game.exe"),
            "v2 merged")
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

    func testNormalizeOwnerWritableNeverFollowsSymlinks() throws {
        // setAttributes resolves symlinks, so normalizing a link
        // would chmod its TARGET - which a hostile archive can point
        // anywhere the sandbox reaches. The link must be skipped
        // while the rest of the tree still normalizes.
        let outside = tempRoot.appendingPathComponent("outside.txt")
        try "outside the tree".write(to: outside, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: outside.path)

        let root = try makeTree("tree", files: ["Data/file.txt": "x"])
        try fm.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: root.appendingPathComponent("Data/file.txt").path)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside)

        try GameTreeUpdate.normalizeOwnerWritable(at: root)

        // attributesOfItem does not traverse the final symlink, so
        // this reads the outside file's own permissions.
        let outsidePermissions =
            try fm.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        XCTAssertEqual(outsidePermissions, 0o444)
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
