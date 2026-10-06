import Foundation
import XCTest

@testable import GameProbe

/// The three notifications of SPEC 7.11, and nothing else.
final class BackupNotificationRuleTests: XCTestCase {

    func testExactlyThreeCausesQualify() {
        XCTAssertEqual(BackupFailFastCause.allCases.count, 3)
    }

    func testEachFailFastStopMapsToItsCause() {
        XCTAssertEqual(BackupNotificationRule.failFastCause(of: .needsSignIn), .signInDead)
        XCTAssertEqual(
            BackupNotificationRule.failFastCause(
                of: .quotaShortfall(
                    QuotaCheck.Shortfall(neededBytes: 10, freeBytes: 1))),
            .targetBlocked)
        XCTAssertEqual(
            BackupNotificationRule.failFastCause(of: .notEnoughLocalSpace), .deviceStorageLow)
    }

    /// A rights problem is not a space problem. The device posted
    /// "empo-dev is full" for a stop that asked for a re-sign-in.
    func testARightsBlockAsksForASignInAndNeverSaysFull() {
        XCTAssertEqual(
            BackupNotificationRule.failFastCause(
                of: .blocked(reason: "this target refused the request.")),
            .signInDead)
        let line = BackupNotificationRule.text(
            for: .signInDead, targetLabel: "empo-dev", deviceName: "iPhone")
        XCTAssertFalse(line.contains("full"))
        XCTAssertTrue(line.contains("Sign in"))
    }

    func testEveryTransientCauseProducesNoNotification() {
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .offline))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .throttled(retryAfter: 30)))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .rejected(message: "slow down")))
        XCTAssertNil(
            BackupNotificationRule.failFastCause(
                of: .readOnlyFormat(.newerFormatVersion(2))))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .noChange))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .blobsOnly))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .failed(reason: "one file")))
    }

    func testTheWriterSplitNeverNotifies() {
        let claim = WriterClaim(
            namespaceId: "ns", deviceId: "other", deviceName: "iPad",
            claimedAt: Date(timeIntervalSince1970: 1))
        XCTAssertNil(BackupNotificationRule.failFastCause(of: .writerConflict(claim)))
        XCTAssertFalse(BackupNotificationRule.writerSplitLine.isEmpty)
    }

    // MARK: - The copy of 7.11

    func testTheCopyStatesTheProblemAndTheFix() {
        XCTAssertEqual(
            BackupNotificationRule.text(
                for: .signInDead, targetLabel: "Dropbox", deviceName: "iPhone"),
            "Sign in to Dropbox again. Your backups are waiting.")
        XCTAssertEqual(
            BackupNotificationRule.text(
                for: .targetBlocked, targetLabel: "Dropbox", deviceName: "iPhone"),
            "Dropbox is full. Make space or raise the cap to continue.")
        XCTAssertEqual(
            BackupNotificationRule.text(
                for: .deviceStorageLow, targetLabel: "Dropbox", deviceName: "iPhone"),
            "iPhone storage is low. Free up space to keep backing up.")
    }

    // MARK: - Once, then re-armed

    func testEachCausePostsOnceAndNotAgainWhileItHolds() {
        var ledger = BackupNotificationLedger()
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t1"), [.signInDead])
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t1"), [])
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t1"), [])
    }

    func testItReArmsOnlyAfterTheBlockerClearsAndReturns() {
        var ledger = BackupNotificationLedger()
        XCTAssertEqual(ledger.post(causes: [.targetBlocked], targetId: "t1"), [.targetBlocked])
        XCTAssertEqual(ledger.post(causes: [], targetId: "t1"), [])
        XCTAssertEqual(ledger.post(causes: [.targetBlocked], targetId: "t1"), [.targetBlocked])
    }

    func testTwoTargetsEachPostTheirOwnSignInNotification() {
        var ledger = BackupNotificationLedger()
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t1"), [.signInDead])
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t2"), [.signInDead])
        XCTAssertEqual(ledger.post(causes: [.signInDead], targetId: "t1"), [])
    }

    func testLowDeviceStorageOnThreeTargetsIsOneNotification() {
        var ledger = BackupNotificationLedger()
        XCTAssertEqual(
            ledger.post(causes: [.deviceStorageLow], targetId: "t1"), [.deviceStorageLow])
        XCTAssertEqual(ledger.post(causes: [.deviceStorageLow], targetId: "t2"), [])
        XCTAssertEqual(ledger.post(causes: [.deviceStorageLow], targetId: "t3"), [])
    }

    // MARK: - Permission

    func testEmpoAsksForPermissionAfterTheFirstTargetAndNeverAtFirstLaunch() {
        XCTAssertFalse(
            BackupNotificationRule.asksForPermission(configuredTargetCount: 0, hasAsked: false))
        XCTAssertTrue(
            BackupNotificationRule.asksForPermission(configuredTargetCount: 1, hasAsked: false))
        XCTAssertFalse(
            BackupNotificationRule.asksForPermission(configuredTargetCount: 2, hasAsked: true))
    }
}
