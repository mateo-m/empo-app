import Foundation
import XCTest

@testable import GameProbe

/// The planner of SPEC 11.1, 11.2, and 11.7, plus the space check of
/// 11.8 and the version-marker sheet of 11.10.
///
/// The rule under every test: the user picked this snapshot on
/// purpose, so the snapshot wins the name, and nothing is deleted.
final class RestorePlanTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        _ path: String,
        root: EntryRoot = .container,
        size: Int64 = 100,
        hash: String = "aa",
        partial: Bool = false,
        source: DetectionSource? = .classifier
    ) -> SnapshotManifest.Entry {
        SnapshotManifest.Entry(
            root: root, path: path, size: size, modifiedAt: stamp, hash: hash,
            compression: .zlib, partial: partial, detectionSource: source)
    }

    private func manifest(
        _ entries: [SnapshotManifest.Entry],
        mode: BackupMode = .slim,
        marker: SnapshotManifest.VersionMarker = SnapshotManifest.VersionMarker(fileCount: 4)
    ) -> SnapshotManifest {
        SnapshotManifest(
            mode: mode, containerFolderName: "Quest", versionMarker: marker, entries: entries)
    }

    // MARK: - The table of 11.2, one test per row

    /// Row 1: restore over a live save file.
    func testRestoreOverALiveSaveFileDisplacesTheLocalOne() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", hash: "new")]),
            scope: .wholeGame,
            localFiles: [
                RestoreLocalFile(
                    root: .container, path: "UserData/save.rxdata", size: 90, hash: "old")
            ])

        XCTAssertEqual(
            plan.steps.map(\.action),
            [.writeAfterDisplacing("UserData/save.rxdata.empo-displaced.bak")])
        XCTAssertEqual(plan.displacementCount, 1)
    }

    /// Row 2: a restore adds files the local tree lacks. Additive,
    /// and the result is the union.
    func testARestoreAddsFilesTheLocalTreeLacksAndDeletesNothing() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata"), entry("UserData/quick.rxdata")]),
            scope: .wholeGame)

        XCTAssertEqual(plan.steps.map(\.action), [.write, .write])
        XCTAssertEqual(plan.displacementCount, 0)
        XCTAssertEqual(plan.writeCount, 2)
    }

    /// Row 3: a full-mode restore over a tree whose version marker
    /// differs fires the warning of 11.10.
    func testAFullModeRestoreOverADifferingMarkerFiresTheSheet() {
        let plan = RestorePlanner.plan(
            manifest: manifest(
                [entry("Game/Data.rvdata")], mode: .full,
                marker: SnapshotManifest.VersionMarker(fileCount: 4)),
            scope: .wholeGame,
            localVersionMarker: SnapshotManifest.VersionMarker(fileCount: 9))

        XCTAssertTrue(plan.showsVersionMarkerSheet)
    }

    /// Row 4: the replace drops only what proven coverage allows.
    /// `ProvenCoverageTests` carries the rest of the row.
    func testTheReplaceDropsOnlyProvenFiles() {
        let snapshot = manifest([entry("Game/Data.rvdata", hash: "covered")], mode: .full)
        let decision = ProvenCoverage.decide(
            mode: .full,
            treeFiles: [
                ProvenCoverage.TreeFile(path: "Data.rvdata", hash: "covered", sizeBytes: 10),
                ProvenCoverage.TreeFile(path: "Extra.rvdata", hash: "unknown", sizeBytes: 20),
            ],
            readableSnapshot: snapshot)

        XCTAssertEqual(decision.drop, ["Data.rvdata"])
        XCTAssertEqual(decision.keep, ["Extra.rvdata"])
    }

    /// Row 7: another device already claims this namespace. The run
    /// stops before any write and defaults to a split, per 5.12.
    func testAnotherDeviceClaimingTheNamespaceStopsBeforeAnyWrite() {
        let claim = WriterClaim(
            namespaceId: "ns-1", deviceId: "other-device", deviceName: "Old iPad",
            claimedAt: stamp)
        let decision = WriterClaimCheck.decide(
            found: claim, deviceId: "this-device", namespaceId: "ns-1")

        guard case .conflict = decision else {
            return XCTFail("a second writer has to conflict")
        }
    }

    /// Row 8: a game is running, so the restore action is
    /// unavailable.
    func testARunningGameClosesTheRestoreDoor() {
        XCTAssertEqual(
            RestorePicker.availability(runInFlight: false, gameIsPlaying: true), .gameIsPlaying)
        XCTAssertEqual(
            RestorePicker.availability(runInFlight: true, gameIsPlaying: false), .runInFlight)
        XCTAssertEqual(
            RestorePicker.availability(runInFlight: false, gameIsPlaying: false), .available)
    }

    /// Row 9: a file that changes during staging re-stages once,
    /// then skips and marks the path partial.
    func testAFileThatChangesDuringStagingRestagesOnceThenMarksPartial() {
        let scanned = FileStamp(size: 10, modifiedAt: stamp)
        let moved = FileStamp(size: 11, modifiedAt: stamp)

        XCTAssertEqual(
            StagingBudget.recheck(scanned: scanned, afterCopy: moved, attempt: 1), .restage)
        XCTAssertEqual(
            StagingBudget.recheck(scanned: scanned, afterCopy: moved, attempt: 2),
            .skipAndMarkPartial)
    }

    /// Row 10: a joined device follows 10.9, so the fresh-install
    /// screen shows no preferences row of its own.
    func testAJoinedDeviceDropsThePreferencesRow() {
        let plan = FreshInstallMerge.plan(
            gameRows: [], preferencesRow: row(snapshotId: snapshotId(0), device: "iPhone"),
            joinedSyncGroup: true)

        XCTAssertNil(plan.preferences)
    }

    /// Row 11: a device that did not join writes the snapshot's
    /// exported keys over the local ones, after it saves the undo.
    func testADeviceThatDidNotJoinWritesTheExportedKeysOverTheLocalOnes() {
        let plan = PreferenceRestore.plan(
            exported: ["theme": .string("dark"), "debugMode": .bool(true)],
            localExport: ["theme": .string("light")],
            portableKeys: ["theme"],
            at: stamp)

        XCTAssertEqual(plan.write, ["theme": .string("dark")])
        XCTAssertEqual(plan.skippedKeys, ["debugMode"])
        XCTAssertEqual(plan.undo.preferences, ["theme": .string("light")])
    }

    // MARK: - Displacement, per 11.1

    func testASecondDisplacementOfOneFileIsNumbered() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", hash: "new")]),
            scope: .wholeGame,
            localFiles: [
                RestoreLocalFile(
                    root: .container, path: "UserData/save.rxdata", size: 90, hash: "old"),
                RestoreLocalFile(
                    root: .container, path: "UserData/save.rxdata.empo-displaced.bak",
                    size: 80, hash: "older"),
            ])

        XCTAssertEqual(
            plan.steps.map(\.action),
            [.writeAfterDisplacing("UserData/save.rxdata.empo-displaced-2.bak")])
    }

    func testADisplacedCopyStaysOutOfTheBackupSet() {
        for number in 1...3 {
            let name = DisplacedCopy.fileName(for: "save.rxdata", number: number)
            XCTAssertTrue(BackupSetRules.carriesDisplacedMarker(name), name)
            XCTAssertTrue(
                BackupSetRules.isAlwaysOut(containerRelativePath: "UserData/" + name), name)
        }
        let tree = DisplacedCopy.treeName(for: "Game", number: 2)
        XCTAssertEqual(tree, "Game.empo-displaced-2")
        XCTAssertTrue(BackupSetRules.carriesDisplacedMarker(tree))
    }

    func testADisplacedNameReadsBackToItsOriginal() {
        XCTAssertEqual(
            DisplacedCopy.originalName(ofDisplaced: "save.rxdata.empo-displaced.bak"),
            "save.rxdata")
        XCTAssertEqual(
            DisplacedCopy.originalName(ofDisplaced: "save.rxdata.empo-displaced-4.bak"),
            "save.rxdata")
        XCTAssertEqual(DisplacedCopy.originalName(ofDisplaced: "Game.empo-displaced"), "Game")
        XCTAssertNil(DisplacedCopy.originalName(ofDisplaced: "save.rxdata"))
        XCTAssertNil(DisplacedCopy.originalName(ofDisplaced: "save.empo-displaced-x.bak"))
    }

    /// Copies are unlimited and never deleted. Empo warns once when
    /// a single file passes three, per 11.12.
    func testTheCopyWarningFiresPastThreeCopies() {
        let names = (1...4).map { DisplacedCopy.fileName(for: "save.rxdata", number: $0) }
        XCTAssertEqual(DisplacedCopy.copyCount(of: "save.rxdata", among: names), 4)
        XCTAssertFalse(DisplacedCopy.warnsAboutCopies(3))
        XCTAssertTrue(DisplacedCopy.warnsAboutCopies(4))
    }

    /// A file whose bytes already match costs nothing and leaves no
    /// copy behind.
    func testAMatchingLocalFileIsLeftAlone() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", hash: "same")]),
            scope: .wholeGame,
            localFiles: [
                RestoreLocalFile(
                    root: .container, path: "UserData/save.rxdata", size: 100, hash: "same")
            ])

        XCTAssertEqual(plan.steps.map(\.action), [.unchanged])
        XCTAssertEqual(plan.bytesToWrite, 0)
        XCTAssertTrue(plan.blobs.isEmpty)
    }

    /// A local file Empo could not hash still displaces, because the
    /// snapshot wins the name.
    func testAnUnreadableLocalFileStillDisplaces() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", hash: "new")]),
            scope: .wholeGame,
            localFiles: [
                RestoreLocalFile(root: .container, path: "UserData/save.rxdata", size: 100)
            ])

        XCTAssertEqual(plan.displacementCount, 1)
    }

    // MARK: - Scope, per 11.7

    func testSavesAndSettingsRestoresExactlyTheSlimMembers() {
        let plan = RestorePlanner.plan(
            manifest: manifest([
                entry("UserData/save.rxdata"),
                entry("Game/Data.rvdata", source: nil),
                entry("EmpoState/backup.json", source: nil),
                entry("bucket/save.rxdata", root: .rescuedSaves, source: nil),
            ]),
            scope: .savesAndSettings)

        XCTAssertEqual(
            plan.steps.map(\.entry.path),
            ["UserData/save.rxdata", "EmpoState/backup.json", "bucket/save.rxdata"])
    }

    func testTheWholeGameScopeRestoresEveryEntry() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata"), entry("Game/Data.rvdata")]),
            scope: .wholeGame)

        XCTAssertEqual(plan.steps.count, 2)
    }

    // MARK: - Blobs

    func testOneBlobIsFetchedOnceForTwoPathsThatShareIt() {
        let plan = RestorePlanner.plan(
            manifest: manifest([
                entry("UserData/a.rxdata", hash: "same"),
                entry("UserData/b.rxdata", hash: "same"),
            ]),
            scope: .wholeGame)

        XCTAssertEqual(plan.blobs.map(\.hash), ["same"])
        XCTAssertEqual(plan.bytesToWrite, 200)
        XCTAssertEqual(plan.bytesToStage, 100)
    }

    /// A restarted run skips a staged blob for free, per 11.9.
    func testAStagedBlobCostsNothingToStageAgain() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", hash: "staged")]),
            scope: .wholeGame,
            stagedBlobHashes: ["staged"])

        XCTAssertEqual(plan.bytesToStage, 0)
        XCTAssertEqual(plan.bytesToWrite, 100)
        XCTAssertTrue(RestoreStaging.toFetch(plan.blobs, staged: ["staged"]).isEmpty)
    }

    // MARK: - Space, per 11.8

    func testTheSpaceCheckRefusesWithTheShortfallNamed() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", size: 1_000)]),
            scope: .wholeGame)

        let shortfall = RestoreSpaceCheck.shortfall(plan: plan, freeSpaceBytes: 500)
        XCTAssertEqual(shortfall?.neededBytes, 2_000)
        XCTAssertEqual(shortfall?.missingBytes, 1_500)
        XCTAssertEqual(
            RestoreSpaceCheck.refusalLine(missingSize: "2.1 GB", deviceName: "iPhone"),
            "This restore needs 2.1 GB more space on this iPhone.")
    }

    func testARestoreThatFitsIsNotRefused() {
        let plan = RestorePlanner.plan(
            manifest: manifest([entry("UserData/save.rxdata", size: 100)]),
            scope: .wholeGame)

        XCTAssertNil(RestoreSpaceCheck.shortfall(plan: plan, freeSpaceBytes: 10_000))
    }

    // MARK: - The version-marker sheet, per 11.10

    func testTheSheetNeverFiresForASavesAndSettingsRestore() {
        let plan = RestorePlanner.plan(
            manifest: manifest(
                [entry("Game/Data.rvdata")], mode: .full,
                marker: SnapshotManifest.VersionMarker(fileCount: 4)),
            scope: .savesAndSettings,
            localVersionMarker: SnapshotManifest.VersionMarker(fileCount: 9))

        XCTAssertFalse(plan.showsVersionMarkerSheet)
    }

    func testTheSheetNeverFiresForASlimSnapshot() {
        XCTAssertFalse(
            VersionMarkerSheet.shows(
                mode: .slim, scope: .wholeGame,
                snapshot: SnapshotManifest.VersionMarker(fileCount: 4),
                local: SnapshotManifest.VersionMarker(fileCount: 9)))
    }

    func testTheSheetNeverFiresWhenTheMarkersMatch() {
        let marker = SnapshotManifest.VersionMarker(gameINIHash: "abc", fileCount: 4)
        XCTAssertFalse(
            VersionMarkerSheet.shows(
                mode: .full, scope: .wholeGame, snapshot: marker, local: marker))
    }

    func testTheThreeActionsCarryTheirScopeAndTheirReplace() {
        XCTAssertEqual(VersionMarkerSheet.actions.first, .savesAndSettingsOnly)
        XCTAssertEqual(VersionMarkerSheet.Action.savesAndSettingsOnly.scope, .savesAndSettings)
        XCTAssertEqual(VersionMarkerSheet.Action.keepMyFiles.scope, .wholeGame)
        XCTAssertFalse(VersionMarkerSheet.Action.keepMyFiles.replacesTheTree)
        XCTAssertTrue(VersionMarkerSheet.Action.useOnlyThisBackup.replacesTheTree)
        XCTAssertFalse(VersionMarkerSheet.body(gameName: "Quest").contains("version"))
    }

    // MARK: - Partial paths, per 11.14

    func testAPartialManifestRestoresAndTheSummaryNamesTheCount() {
        let plan = RestorePlanner.plan(
            manifest: manifest([
                entry("UserData/save.rxdata", hash: "a"),
                entry("UserData/quick.rxdata", hash: "b", partial: true),
            ]),
            scope: .wholeGame)

        XCTAssertEqual(plan.writeCount, 2)
        XCTAssertEqual(plan.partialPaths, ["UserData/quick.rxdata"])
        XCTAssertEqual(
            RestoreNotices.partialPathsLine(count: plan.partialPaths.count),
            "1 file was being written when this backup ran and was left out.")
    }

    func testTheSummaryStaysSilentWhenNoPathWasPartial() {
        XCTAssertNil(RestoreNotices.partialPathsLine(count: 0))
        XCTAssertEqual(
            RestoreNotices.partialPathsLine(count: 3),
            "3 files were being written when this backup ran and were left out.")
    }

    // MARK: - Helpers

    private func snapshotId(_ offset: TimeInterval) -> String {
        BackupKeys.snapshotId(date: stamp.addingTimeInterval(offset), suffix: "abcdef")
    }

    private func row(
        snapshotId: String, device: String, folderName: String = "Quest"
    ) -> SnapshotRow {
        SnapshotRow(
            targetId: "target-1", targetLabel: "Homelab", namespaceId: "ns-1",
            deviceName: device, snapshotId: snapshotId,
            createdAt: BackupKeys.timestamp(ofSnapshotId: snapshotId) ?? stamp,
            mode: .slim, bytesToDownload: 10, hasPartialPaths: false,
            versionMarkerDiffers: false,
            identity: SnapshotIdentity(containerFolderName: folderName))
    }
}
