import Foundation
import XCTest

@testable import GameProbe

/// The progress pill, the run plan, the card badge, and the resume
/// question of SPEC 13.2, 13.3, and 13.18.
final class RunProgressTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let gameKey = BackupKeys.gameKey(containerFolderName: "Rejuvenation")

    private func plan(_ bytes: Int64) -> BackupRunPlan {
        var plan = BackupRunPlan()
        plan.plan(streamKey: gameKey, bytes: bytes)
        return plan
    }

    private func shows(
        _ plan: BackupRunPlan, at seconds: TimeInterval, ended: TimeInterval? = nil
    )
        -> Bool
    {
        ProgressPill.shows(
            startedAt: start,
            finishedAt: ended.map { start.addingTimeInterval($0) },
            hasUploads: plan.hasUploads,
            gameIsPlaying: false,
            now: start.addingTimeInterval(seconds))
    }

    // MARK: - 1. The two clocks of the pill

    func testThePillWaitsTwoSecondsAndHidesFiveSecondsAfterTheEnd() {
        let plan = plan(1_000)
        XCTAssertFalse(shows(plan, at: 1.9))
        XCTAssertTrue(shows(plan, at: 2))
        XCTAssertTrue(shows(plan, at: 30))

        XCTAssertTrue(shows(plan, at: 34, ended: 30))
        XCTAssertFalse(shows(plan, at: 35, ended: 30))
    }

    func testThePillHidesWhileAGamePlays() {
        XCTAssertFalse(
            ProgressPill.shows(
                startedAt: start, finishedAt: nil, hasUploads: true,
                gameIsPlaying: true, now: start.addingTimeInterval(10)))
    }

    // MARK: - 2. A run with nothing to upload

    func testARunWithNothingToUploadNeverShowsThePill() {
        var empty = BackupRunPlan()
        empty.plan(streamKey: gameKey, bytes: 0)
        XCTAssertFalse(empty.hasUploads)
        XCTAssertFalse(shows(empty, at: 60))
        XCTAssertNil(empty.fraction)
    }

    // MARK: - 3. The plan freezes at staging end

    func testTheRunPlanFreezesAndAFileChangedMidRunDoesNotChangeTheTotal() {
        var plan = plan(2_000)
        plan.confirm(streamKey: gameKey, bytes: 500)
        // The same stream stages once. A second call is the file
        // that changed mid-run, and it joins the next snapshot.
        plan.plan(streamKey: gameKey, bytes: 9_000)
        XCTAssertEqual(plan.plannedBytes, 2_000)
        XCTAssertEqual(plan.bytesLeft, 1_500)

        // A second stream carries its own frozen part.
        plan.plan(streamKey: "other", bytes: 1_000)
        XCTAssertEqual(plan.plannedBytes, 3_000)
    }

    // MARK: - 4. What moves the progress

    func testProgressAdvancesOnAConfirmedBlobAndNotOnAStartedUpload() {
        var plan = plan(1_000)
        XCTAssertEqual(plan.confirmedBytes, 0)
        XCTAssertEqual(plan.fraction, 0)

        plan.confirm(streamKey: gameKey, bytes: 250)
        XCTAssertEqual(plan.fraction, 0.25)
        XCTAssertEqual(plan.fraction(ofStream: gameKey), 0.25)
        XCTAssertFalse(plan.isDone(gameKey))

        plan.confirm(streamKey: gameKey, bytes: 750)
        XCTAssertEqual(plan.fraction, 1)
        XCTAssertTrue(plan.isDone(gameKey))
    }

    func testTheBadgeSpinsUntilTheFirstStreamFreezesItsPlan() {
        var plan = BackupRunPlan()
        XCTAssertNil(plan.fraction)
        XCTAssertNil(plan.fraction(ofStream: gameKey))
        plan.plan(streamKey: gameKey, bytes: 400)
        XCTAssertEqual(plan.fraction, 0)
    }

    // MARK: - 5 and 6. The badge and the status line

    func testTheBadgeMatchesTheStatusLineForAllEightStates() {
        let expected: [(GameBackupState, GameBackupBadge)] = [
            (.running, .uploading),
            (.paused, .paused),
            (.failed(.needsSignIn), .failed),
            (.waitingForWiFi, .none),
            (.stale(days: 9), .stale),
            (.healthy, .none),
            (.neverRun, .none),
            (.notSetUp, .none),
        ]
        for (state, badge) in expected {
            XCTAssertEqual(GameBackupStatus(state: state).badge, badge, "\(state)")
        }
    }

    func testAGameThatIsBackedUpAndCurrentShowsNoBadge() {
        let target = GameTargetState(
            targetId: "a", displayName: "Dropbox", lastSuccessAt: start)
        let status = GameBackupStatusRules.status(
            targets: [target], isRunning: false, now: start)
        XCTAssertEqual(status.state, .healthy)
        XCTAssertEqual(status.badge, .none)
    }

    // MARK: - 7. The floor of the resume question

    private func interrupted(uploaded: Int64, asked: Bool = false) -> BackupIntentRecord {
        BackupIntentRecord(
            kind: .interruptedRun,
            targetId: "a",
            gameKey: gameKey,
            uploadedBytes: uploaded,
            remainingBytes: 2_800,
            createdAt: start,
            asked: asked)
    }

    func testTheResumeQuestionFiresAboveTheFloorAndNotBelowIt() {
        let floor = BackupIntentRecord.resumeQuestionFloorBytes
        XCTAssertTrue(BackupResumeQuestion.asks(interrupted(uploaded: floor)))
        XCTAssertFalse(BackupResumeQuestion.asks(interrupted(uploaded: floor - 1)))
        XCTAssertFalse(BackupResumeQuestion.asks(nil))
    }

    func testTheSameInterruptionNeverAsksTwice() {
        let floor = BackupIntentRecord.resumeQuestionFloorBytes
        XCTAssertFalse(BackupResumeQuestion.asks(interrupted(uploaded: floor, asked: true)))
    }

    func testAPausedRunNeverAsksAtTheNextLaunch() {
        var record = interrupted(uploaded: 4 * BackupIntentRecord.resumeQuestionFloorBytes)
        record.kind = .pausedRun
        XCTAssertFalse(BackupResumeQuestion.asks(record))
        XCTAssertFalse(record.asksAtNextLaunch)
    }

    func testTheQuestionNamesTheGameAndWhatRemains() {
        XCTAssertEqual(
            BackupResumeQuestion.question(gameName: "Rejuvenation", leftText: "2.8 GB"),
            "Resume backing up Rejuvenation? About 2.8 GB left.")
        XCTAssertEqual(
            BackupResumeQuestion.Action.allCases.map(BackupResumeQuestion.label),
            ["Resume", "Later", "Stop backup"])
    }

    // MARK: - 8. What each answer leaves behind

    func testEachResumeActionLeavesTheRightState() {
        let resume = BackupResumeQuestion.effect(of: .resume)
        XCTAssertTrue(resume.startsRunNow)
        XCTAssertTrue(resume.keepsRecord)
        XCTAssertFalse(resume.cleansStagingAndOutbox)

        let later = BackupResumeQuestion.effect(of: .later)
        XCTAssertFalse(later.startsRunNow)
        XCTAssertTrue(later.keepsRecord)
        XCTAssertFalse(later.cleansStagingAndOutbox)

        let stop = BackupResumeQuestion.effect(of: .stop)
        XCTAssertFalse(stop.startsRunNow)
        XCTAssertFalse(stop.keepsRecord)
        XCTAssertTrue(stop.cleansStagingAndOutbox)
    }

    func testTheRestoreSideKeepsTheScopeTheUserChose() {
        let record = RestoreResumeQuestion.record(
            targetId: "a", gameKey: gameKey, snapshotId: "s1",
            scope: .savesAndSettings, replacesTheTree: false, at: start)
        XCTAssertEqual(record.restoreScope, .savesAndSettings)
        XCTAssertFalse(record.replacesTheTree)
        XCTAssertTrue(RestoreResumeQuestion.asks(record))
    }

    // MARK: - 9. The notification gate

    private var claim: WriterClaim {
        WriterClaim(namespaceId: "n1", deviceId: "d1", deviceName: "iPad", claimedAt: start)
    }

    func testTheGateFiresForTheThreeCausesOnceEachAndRearmsAfterTheBlockerClears() {
        var ledger = BackupNotificationLedger()
        let all: Set<BackupFailFastCause> = [.signInDead, .targetBlocked, .deviceStorageLow]

        XCTAssertEqual(Set(ledger.post(causes: all, targetId: "a")), all)
        XCTAssertTrue(ledger.post(causes: all, targetId: "a").isEmpty)

        // The blocker cleared, so the cause leaves the ledger and
        // arms again.
        XCTAssertTrue(ledger.post(causes: [], targetId: "a").isEmpty)
        XCTAssertEqual(Set(ledger.post(causes: all, targetId: "a")), all)
    }

    func testEveryTransientCauseProducesNoNotification() {
        let transient: [BackupRunStop] = [
            .writerConflict(claim),
            .readOnlyFormat(.newerFormatVersion(2)),
            .offline,
            .throttled(retryAfter: 30),
            .rejected(message: "the target said no"),
        ]
        for stop in transient {
            XCTAssertNil(BackupNotificationRule.failFastCause(of: stop), "\(stop)")
        }
        XCTAssertNil(BackupNotificationRule.failFastCause(of: StreamOutcome.noChange))
        XCTAssertEqual(
            BackupNotificationRule.failFastCause(of: StreamOutcome.notEnoughLocalSpace),
            .deviceStorageLow)
    }

    // MARK: - 10. The writer split

    func testTheWriterSplitProducesTheLineAndNoNotification() {
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .writerConflict(claim)))
        XCTAssertEqual(
            BackupNotificationRule.writerSplitLine,
            "Another device was using this backup location. New snapshots go to a new space, "
                + "and both keep their history.")
    }

    // MARK: - The pill's four wordings, per 13.2

    func testThePillSaysTheFourLinesOfThirteenTwo() {
        XCTAssertEqual(ProgressPill.line(.preparing), "Preparing…")
        XCTAssertEqual(
            ProgressPill.line(.uploading(gameName: "Rejuvenation"), leftText: "2.4 GB"),
            "Backing up Rejuvenation, about 2.4 GB left")
        XCTAssertEqual(
            ProgressPill.line(.paused(reason: "a game is running")),
            "Paused, a game is running")
        XCTAssertEqual(ProgressPill.line(.complete), "Backup complete")
    }

    // MARK: - The 21-day banner, per 7.1

    func testTheBannerNamesTheCauseAndCarriesOneAction() {
        let banner = LibraryStaleBanner(
            cause: .needsSignIn, action: .signInAgain, targetId: "a", gameCount: 3)
        XCTAssertEqual(
            banner.line(targetLabel: "Dropbox"),
            "3 games have had no backup for 3 weeks, Dropbox needs you to sign in again.")
        XCTAssertEqual(banner.action.label, "Sign in again")
    }
}
