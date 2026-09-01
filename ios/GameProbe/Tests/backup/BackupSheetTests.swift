import Foundation
import XCTest

@testable import GameProbe

/// The per-game Backup sheet of SPEC 13.15 to 13.18.
final class BackupSheetTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func target(
        _ id: String,
        name: String? = nil,
        paused: Bool = false,
        cause: StaleCause? = nil,
        daysAgo: Double? = 0,
        playedDaysAgo: Double? = 0
    ) -> GameTargetState {
        GameTargetState(
            targetId: id,
            displayName: name ?? id,
            isPaused: paused,
            cause: cause,
            lastSuccessAt: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            lastPlayedAt: playedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    // MARK: - 1. The eight states, in precedence order

    func testTheEightStatesRankInTheOrderOfThirteenSixteen() {
        let ranks = [
            GameBackupState.running, .paused, .failed(.needsSignIn), .waitingForWiFi,
            .stale(days: 9), .healthy, .neverRun, .notSetUp,
        ].map(\.rank)
        XCTAssertEqual(ranks, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testEachStateOutranksTheOneBelowIt() {
        let dropbox = target("a", cause: .needsSignIn, daysAgo: 30)
        let running = GameBackupStatusRules.status(
            targets: [dropbox], isRunning: true, now: now)
        XCTAssertEqual(running.state, .running)

        let paused = GameBackupStatusRules.status(
            targets: [target("a", paused: true, cause: .needsSignIn)], isRunning: false, now: now)
        XCTAssertEqual(paused.state, .paused)

        let failed = GameBackupStatusRules.status(
            targets: [dropbox], isRunning: false, now: now)
        XCTAssertEqual(failed.state, .failed(.needsSignIn))

        let waiting = GameBackupStatusRules.status(
            targets: [target("a", cause: .waitingForWiFi, daysAgo: 30)], isRunning: false,
            now: now)
        XCTAssertEqual(waiting.state, .waitingForWiFi)

        let stale = GameBackupStatusRules.status(
            targets: [target("a", daysAgo: 12)], isRunning: false, now: now)
        XCTAssertEqual(stale.state, .stale(days: 12))

        let healthy = GameBackupStatusRules.status(
            targets: [target("a", daysAgo: 0)], isRunning: false, now: now)
        XCTAssertEqual(healthy.state, .healthy)

        let never = GameBackupStatusRules.status(
            targets: [target("a", daysAgo: nil)], isRunning: false, now: now)
        XCTAssertEqual(never.state, .neverRun)

        XCTAssertEqual(
            GameBackupStatusRules.status(targets: [], isRunning: false, now: now).state, .notSetUp)
    }

    func testTheLineAndTheBadgeReadOneLadder() {
        // A play after the last success starts the clock of 7.1.
        // The line, the badge, and the banner count from the same
        // date, so no screen calls a game late while another calls
        // it current.
        for days in [0.0, 3, 6, 6.9, 7, 12, 21, 40] {
            let late = target("a", daysAgo: days, playedDaysAgo: 0)
            let status = GameBackupStatusRules.status(
                targets: [late], isRunning: false, now: now)
            let level = Staleness.level(of: late.freshness, now: now)
            XCTAssertEqual(
                status.state == .stale(days: Int(days)), level != .fresh,
                "the two ladders disagree at \(days) days")
            XCTAssertEqual(status.badge == .stale, level != .fresh)
        }
    }

    func testTheLineNamesATargetOnlyWhenExactlyOneIsAtFault() {
        let one = GameBackupStatusRules.status(
            targets: [
                target("a", name: "Dropbox", cause: .needsSignIn, daysAgo: 30),
                target("b", name: "homelab", daysAgo: 0),
            ], isRunning: false, now: now)
        XCTAssertEqual(one.targetLabel, "Dropbox")
        XCTAssertEqual(one.causeLine, "Dropbox needs you to sign in again")

        let two = GameBackupStatusRules.status(
            targets: [
                target("a", name: "Dropbox", cause: .needsSignIn, daysAgo: 30),
                target("b", name: "homelab", cause: .targetBlocked, daysAgo: 30),
            ], isRunning: false, now: now)
        XCTAssertNil(two.targetLabel)
        XCTAssertEqual(two.line(), "Last backup failed")
    }

    func testTheHealthyLineNamesTheOneTargetAndTheDay() {
        let status = GameBackupStatusRules.status(
            targets: [target("a", name: "Dropbox", daysAgo: 0)], isRunning: false, now: now)
        XCTAssertEqual(status.line(lastSuccessText: "today"), "Backed up today · Dropbox")
    }

    func testAPausedTargetLeavesTheComputation() {
        let status = GameBackupStatusRules.status(
            targets: [
                target("a", name: "Dropbox", paused: true, cause: .needsSignIn, daysAgo: 30),
                target("b", name: "homelab", daysAgo: 0),
            ], isRunning: false, now: now)
        XCTAssertEqual(status.state, .healthy)
        XCTAssertEqual(status.targetLabel, "homelab")
    }

    // MARK: - 2. The badge reads the same computation, per 13.3

    func testTheBadgeAndTheLineAgreeOnEveryState() {
        let pairs: [(GameBackupState, GameBackupBadge)] = [
            (.running, .uploading),
            (.paused, .paused),
            (.failed(.targetBlocked), .failed),
            (.waitingForWiFi, .none),
            (.stale(days: 9), .stale),
            (.healthy, .none),
            (.neverRun, .none),
            (.notSetUp, .none),
        ]
        for (state, badge) in pairs {
            XCTAssertEqual(GameBackupStatus(state: state).badge, badge)
        }
    }

    // MARK: - 3 and 4. The locks of 13.17

    func testARunInFlightTurnsBackUpNowIntoPauseAndFreezesTheSet() {
        let locks = BackupSheetLockRules.locks(runInFlight: true, openGameName: nil)
        XCTAssertTrue(locks.backUpNowIsPause)
        XCTAssertTrue(locks.canBackUpNow)
        XCTAssertFalse(locks.canRestore)
        XCTAssertFalse(locks.canChangeMode)
        XCTAssertFalse(locks.canEditSaveFiles)
        XCTAssertEqual(locks.footer, BackupSheetLockRules.runInFlightLine)
    }

    func testAnOpenGameDisablesTheFourActionsAndLeavesTheSetEditable() {
        let locks = BackupSheetLockRules.locks(runInFlight: false, openGameName: "Ib")
        XCTAssertFalse(locks.canBackUpNow)
        XCTAssertFalse(locks.canRestore)
        XCTAssertFalse(locks.canExport)
        XCTAssertFalse(locks.canDeleteLeftovers)
        XCTAssertTrue(locks.canChangeMode)
        XCTAssertTrue(locks.canEditSaveFiles)
        XCTAssertEqual(locks.footer, "Close Ib to use these.")
    }

    func testAnOpenGameOutranksARunInFlight() {
        let locks = BackupSheetLockRules.locks(runInFlight: true, openGameName: "Ib")
        XCTAssertTrue(locks.canChangeMode)
        XCTAssertFalse(locks.backUpNowIsPause)
    }

    func testNothingLocksWhenTheGameSitsStill() {
        let locks = BackupSheetLockRules.locks(runInFlight: false, openGameName: nil)
        XCTAssertNil(locks.footer)
        XCTAssertTrue(locks.canBackUpNow)
        XCTAssertTrue(locks.canRestore)
        XCTAssertTrue(locks.canDeleteLeftovers)
    }

    // MARK: - 5. A mode change, per 3.9

    func testAModeChangeMakesTheGameDirtyAndADowngradeTouchesNoRemote() {
        var intent = GameBackupIntent()
        intent = BackupModeChange.apply(.full, to: intent)
        XCTAssertEqual(intent.mode, .full)
        XCTAssertTrue(BackupModeChange.makesDirty(from: nil, to: .full))
        XCTAssertTrue(BackupModeChange.makesDirty(from: .full, to: .slim))
        XCTAssertFalse(BackupModeChange.makesDirty(from: .slim, to: .slim))

        // A downgrade is a statement about future snapshots. The
        // older full-mode snapshots stay until retention drops them.
        let downgraded = BackupModeChange.apply(.slim, to: intent)
        XCTAssertEqual(downgraded.mode, .slim)
        XCTAssertEqual(downgraded.manualMarks, intent.manualMarks)
    }

    // MARK: - 6 and 7. Every game gets the row, per 13.15

    func testAGameBelowTheThresholdNeverMeetsTheAsk() {
        let resolution = BackupThreshold.resolveMode(
            intent: GameBackupIntent(),
            gameTreeBytes: 40 * 1024 * 1024,
            targets: [BackupTargetThreshold(targetId: "a", displayName: "Dropbox")])
        XCTAssertEqual(resolution, .mode(.full))
    }

    func testWithNoTargetTheRowReadsNotSetUp() {
        let status = GameBackupStatusRules.status(targets: [], isRunning: false, now: now)
        XCTAssertEqual(status.line(), "Not set up")
        XCTAssertEqual(status.badge, .none)
    }

    // MARK: - 8. The version-marker sheet, per 11.10

    func testTheVersionMarkerSheetFiresOnlyForAFullModeRestoreWithADifferentMarker() {
        let snapshot = SnapshotManifest.VersionMarker(
            gameINIHash: "a", fileCount: 90, totalSize: 10)
        let local = SnapshotManifest.VersionMarker(
            gameINIHash: "b", fileCount: 90, totalSize: 10)
        XCTAssertTrue(
            VersionMarkerSheet.shows(
                mode: .full, scope: .wholeGame, snapshot: snapshot, local: local))
        XCTAssertFalse(
            VersionMarkerSheet.shows(
                mode: .full, scope: .savesAndSettings, snapshot: snapshot, local: local))
        XCTAssertFalse(
            VersionMarkerSheet.shows(
                mode: .slim, scope: .wholeGame, snapshot: snapshot, local: local))
        XCTAssertEqual(
            VersionMarkerSheet.actions.map(\.label),
            ["Saves and settings only", "Keep my files", "Use only this backup"])
    }

    // MARK: - The one picker behind two doors, per 3.5

    func testThePickerHoldsTheSameTwoRowsForTheAskAndTheModeRow() {
        let options = BackupModePicker.options(fullBytes: 2_400_000_000, slimBytes: 4_000_000)
        XCTAssertEqual(options.map(\.mode), [.full, .slim])
        XCTAssertEqual(options[0].sizeBytes, 2_400_000_000)
        XCTAssertEqual(BackupModePicker.label(of: nil), "Not chosen yet")
        XCTAssertEqual(BackupModePicker.label(of: .full), options[0].label)
        XCTAssertEqual(BackupModePicker.label(of: .slim), options[1].label)
    }

    // MARK: - The leftovers of 11.12

    func testTheLeftoverConfirmationsNameWhatGoesAndOfferNoDeleteAll() {
        let tree = RestoreLeftovers.replacedTreeConfirmation(
            gameName: "Ib", sizeText: "1.2 GB")
        XCTAssertTrue(tree.body.contains("1.2 GB"))
        XCTAssertTrue(tree.body.contains("Ib"))

        let copies = RestoreLeftovers.displacedCopiesConfirmation(count: 4, sizeText: "12 MB")
        XCTAssertEqual(copies.buttonLabel, "Delete 4 files")
        XCTAssertEqual(
            RestoreLeftovers.displacedCopiesConfirmation(count: 1, sizeText: "3 MB").buttonLabel,
            "Delete 1 file")
        XCTAssertEqual(
            RestoreLeftovers.displacedCopiesRow(count: 1, sizeText: "3 MB"),
            "1 replaced file, 3 MB")
    }

    func testTheCopyWarningFiresOnlyPastThreeCopies() {
        XCTAssertNil(RestoreLeftovers.copyWarning(fileName: "Save1.rvdata2", count: 3))
        XCTAssertNotNil(RestoreLeftovers.copyWarning(fileName: "Save1.rvdata2", count: 4))
    }

    // MARK: - The cause a target failure leaves on a game

    func testARightsBlockAsksForASignInAndATransientFailureSaysNothing() {
        XCTAssertEqual(StaleCause.of(.needsSignIn), .needsSignIn)
        XCTAssertEqual(
            StaleCause.of(.blockedByPermissions(reason: "no delete right")), .needsSignIn)
        XCTAssertEqual(StaleCause.of(.full(reason: "the drive is full")), .targetBlocked)
        XCTAssertNil(StaleCause.of(.unreachable))
        XCTAssertNil(StaleCause.of(.rejected(message: "bad request")))
        XCTAssertNil(StaleCause.of(nil))
    }

    func testATargetFailureThatSaysNothingLeavesTheGameOnTheClock() {
        let unreachable = GameTargetState(
            targetId: "a",
            displayName: "homelab",
            cause: StaleCause.of(.unreachable),
            lastSuccessAt: now.addingTimeInterval(-9 * 86_400),
            lastPlayedAt: now)
        let status = GameBackupStatusRules.status(
            targets: [unreachable], isRunning: false, now: now)
        XCTAssertEqual(status.state, .stale(days: 9))
    }

    // MARK: - The version marker from a picker row

    func testTheMarkerSheetReadsAPickerRowTheSameWayItReadsTwoMarkers() {
        XCTAssertTrue(
            VersionMarkerSheet.shows(mode: .full, scope: .wholeGame, markerDiffers: true))
        XCTAssertFalse(
            VersionMarkerSheet.shows(mode: .full, scope: .wholeGame, markerDiffers: false))
        XCTAssertFalse(
            VersionMarkerSheet.shows(mode: .slim, scope: .wholeGame, markerDiffers: true))
        XCTAssertFalse(
            VersionMarkerSheet.shows(
                mode: .full, scope: .savesAndSettings, markerDiffers: true))
    }
}
