import Foundation
import XCTest

@testable import GameProbe

/// The Backups screen of SPEC 13.4 to 13.14 and 13.19.
final class BackupsScreenTests: XCTestCase {

    private let failedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func target(
        id: String = "t1",
        provider: BackupProviderKind = .dropbox,
        label: String = "Dropbox",
        accountHint: String? = "sam@example.com",
        capBytes: Int64? = nil,
        isPaused: Bool = false
    ) -> TargetDescriptor {
        TargetDescriptor(
            id: id, provider: provider, label: label, accountHint: accountHint,
            root: "/Empo Backups", capBytes: capBytes, isPaused: isPaused)
    }

    /// Every state, worst first, with the facts that produce it.
    private func factsInRankOrder() -> [TargetRowFacts] {
        [
            TargetRowFacts(descriptor: target(), reach: .iCloudDriveOff),
            TargetRowFacts(descriptor: target(accountHint: nil)),
            TargetRowFacts(descriptor: target(isPaused: true), hasPlus: false),
            TargetRowFacts(descriptor: target(isPaused: true)),
            TargetRowFacts(descriptor: target(), failure: .needsSignIn),
            TargetRowFacts(
                descriptor: target(), failure: .blockedByPermissions(reason: "no write right")),
            TargetRowFacts(descriptor: target(), failure: .rejected(message: "too big")),
            TargetRowFacts(descriptor: target(), failure: .full(reason: "no room")),
            TargetRowFacts(descriptor: target(), failure: .unreachable(), failedAt: failedAt),
            TargetRowFacts(descriptor: target()),
        ]
    }

    // MARK: - 1. The ten states, highest first

    func testEveryPairOfStatesKeepsTheOrderOfTheSpec() {
        let states = factsInRankOrder().map(TargetRowRules.state(of:))
        XCTAssertEqual(states.map(\.rank), Array(1...10))
        for (index, state) in states.enumerated() {
            for other in states[(index + 1)...] {
                XCTAssertLessThan(
                    state.rank, other.rank,
                    "\(state) must outrank \(other)")
            }
        }
    }

    func testPausedOutranksNeedsSignIn() {
        let facts = TargetRowFacts(
            descriptor: target(isPaused: true), failure: .needsSignIn)
        XCTAssertEqual(TargetRowRules.state(of: facts), .paused)
    }

    func testEveryServiceButICloudDriveNeedsPlus() {
        let free = BackupProviderKind.allCases.filter { !$0.needsPlus }
        XCTAssertEqual(free, [.iCloudDrive])
    }

    func testALocationWithoutPlusOffersPlusAndSaysRestoreStillWorks() {
        let row = TargetRowRules.row(
            TargetRowFacts(descriptor: target(), failure: .needsSignIn, hasPlus: false))
        XCTAssertEqual(row.state, .needsPlus)
        XCTAssertEqual(row.stateLine, "Backups stopped. You can still restore.")
        XCTAssertEqual(row.action, .getPlus)
        XCTAssertFalse(row.isDisabled)
    }

    func testICloudDriveBacksUpWithoutPlus() {
        let facts = TargetRowFacts(
            descriptor: target(provider: .iCloudDrive, label: "iCloud Drive"),
            hasPlus: false)
        XCTAssertEqual(TargetRowRules.state(of: facts), .current)
    }

    func testThePlaceholderSitsAtPositionTwo() {
        let facts = TargetRowFacts(
            descriptor: target(accountHint: nil, isPaused: true), failure: .needsSignIn)
        XCTAssertEqual(TargetRowRules.state(of: facts), .placeholder)
        XCTAssertEqual(TargetRowRules.state(of: facts).rank, 2)
        XCTAssertEqual(TargetRowRules.action(for: .placeholder), .signIn)
    }

    func testACannotOpenTargetKeepsItsRowAndTakesNoAction() {
        let row = TargetRowRules.row(
            TargetRowFacts(
                descriptor: target(provider: .iCloudDrive, label: "", accountHint: nil),
                reach: .iCloudDriveOff))
        XCTAssertEqual(row.title, "iCloud Drive")
        XCTAssertEqual(row.stateLine, TargetRowRules.iCloudOffLine)
        XCTAssertNil(row.action)
        XCTAssertTrue(row.isDisabled)
    }

    func testASignedOutICloudTargetSaysSo() {
        let row = TargetRowRules.row(
            TargetRowFacts(
                descriptor: target(provider: .iCloudDrive, label: "", accountHint: nil),
                reach: .signedOut))
        XCTAssertEqual(row.stateLine, TargetRowRules.iCloudSignedOutLine)
        XCTAssertTrue(row.isDisabled)
    }

    func testTheUnreachableLineReadsAsAPastEventWithATime() {
        let row = TargetRowRules.row(
            TargetRowFacts(
                descriptor: target(label: "Homelab", accountHint: "homelab.lan"),
                failure: .unreachable(), failedAt: failedAt,
                failedAtText: "yesterday at 14:03"))
        XCTAssertEqual(row.stateLine, "Couldn't connect yesterday at 14:03")
        XCTAssertEqual(row.action, .tryAgain)
        XCTAssertTrue(row.state.isProblem)
    }

    func testAServerThatAnsweredDoesNotReadAsNoConnection() {
        let lines = [UnreachableCause.serverError, .busy].map { cause in
            TargetRowRules.row(
                TargetRowFacts(
                    descriptor: target(), failure: .unreachable(cause), failedAt: failedAt,
                    failedAtText: "at 14:03")
            ).stateLine
        }
        XCTAssertEqual(lines, ["Server error at 14:03", "Server busy at 14:03"])
    }

    func testAFullLocationOffersTryAgainAndNotAButtonThatDoesNothing() {
        XCTAssertEqual(TargetRowRules.action(for: .full(reason: "")), .tryAgain)
        XCTAssertEqual(TargetRowAction.tryAgain.label, "Try again")
        XCTAssertTrue(QuotaCheck.prunedAndStillFullLine.contains("storage limit"))
        XCTAssertFalse(QuotaCheck.prunedAndStillFullLine.contains("cap"))
    }

    func testARefusedRequestOffersTryAgain() {
        XCTAssertEqual(
            TargetRowRules.action(for: .rejected(message: "The server refused the request.")),
            .tryAgain)
    }

    func testOnlyAProblemDrawsAsOne() {
        XCTAssertFalse(TargetRowState.current.isProblem)
        XCTAssertFalse(TargetRowState.paused.isProblem)
        XCTAssertFalse(TargetRowState.placeholder.isProblem)
        XCTAssertFalse(TargetRowState.cannotOpen(.signedOut).isProblem)
        XCTAssertTrue(TargetRowState.needsSignIn.isProblem)
    }

    func testAForegroundOnlyTargetCarriesThePermanentLine() {
        let row = TargetRowRules.row(
            TargetRowFacts(descriptor: target(), supportsBackgroundTransfer: false))
        XCTAssertEqual(row.foregroundOnlyLine, "Backs up only while Empo is open")
    }

    // MARK: - 2. The status line

    func testTheStatusLineNamesTheWorstEnabledTargetOfThree() {
        let targets = [
            TargetRowFacts(descriptor: target(id: "a", label: "Homelab")),
            TargetRowFacts(
                descriptor: target(id: "b", label: "Dropbox"), failure: .needsSignIn),
            TargetRowFacts(
                descriptor: target(id: "c", label: "S3"), failure: .full(reason: "no room")),
        ]
        let status = BackupsScreenStatusRules.status(of: targets)
        XCTAssertEqual(status?.line, "Check Dropbox")
        XCTAssertEqual(status?.detail, "Sign in again to continue")
        XCTAssertEqual(status?.targetId, "b")
        XCTAssertEqual(status?.isHealthy, false)
    }

    func testAPausedTargetLeavesTheStatusComputation() {
        let targets = [
            TargetRowFacts(
                descriptor: target(id: "a", label: "Dropbox", isPaused: true),
                failure: .needsSignIn),
            TargetRowFacts(
                descriptor: target(id: "b", label: "Homelab"), lastSuccessText: "2 minutes ago"),
        ]
        let status = BackupsScreenStatusRules.status(of: targets, lastSuccessText: "today")
        XCTAssertEqual(status?.line, "All games backed up")
        XCTAssertEqual(status?.detail, "Last backup today")
        XCTAssertTrue(status?.isHealthy == true)
        let fresh = BackupsScreenStatusRules.status(
            of: [TargetRowFacts(descriptor: target(id: "b", label: "Homelab"))])
        XCTAssertEqual(fresh?.line, "Ready to back up")
        XCTAssertEqual(fresh?.detail, "No backup yet")
    }

    func testALocationWithNoBackupYetKeepsTheOthersFromCallingItDone() {
        let targets = [
            TargetRowFacts(
                descriptor: target(id: "a", label: "Dropbox"), lastSuccessText: "2 minutes ago"),
            TargetRowFacts(descriptor: target(id: "b", label: "Homelab")),
        ]
        let status = BackupsScreenStatusRules.status(of: targets, lastSuccessText: "today")
        XCTAssertEqual(status?.line, "Ready to back up")
        XCTAssertEqual(status?.detail, "No backup yet at Homelab")
    }

    /// Waiting for Wi-Fi is no target failure, so the row stays
    /// current while the games go weeks without a backup.
    func testGamesWithNoBackupForWeeksKeepTheCardFromCallingItDone() {
        let targets = [
            TargetRowFacts(
                descriptor: target(id: "a", label: "Dropbox"), lastSuccessText: "3 weeks ago"),
            TargetRowFacts(
                descriptor: target(id: "b", label: "Homelab"), lastSuccessText: "3 weeks ago"),
        ]
        let since = failedAt.addingTimeInterval(-22 * 86_400)
        let games = [
            GameFreshness(gameKey: "g1"),
            GameFreshness(
                gameKey: "g2", level: .stale, targetId: "a", cause: .waitingForWiFi,
                unprotectedSince: since.addingTimeInterval(86_400)),
            GameFreshness(
                gameKey: "g3", level: .banner, targetId: "b", cause: .waitingForWiFi,
                unprotectedSince: since),
        ]
        let status = BackupsScreenStatusRules.status(
            of: targets, games: games, lastSuccessText: "on 4 March")
        XCTAssertEqual(status?.line, "2 games not backed up")
        XCTAssertEqual(status?.detail, "Empo is waiting for Wi-Fi.")
        XCTAssertEqual(status?.targetId, "b")
        XCTAssertEqual(status?.isHealthy, false)

        let one = BackupsScreenStatusRules.status(
            of: targets, games: [games[1]], lastSuccessText: "on 4 March")
        XCTAssertEqual(one?.line, "1 game not backed up")

        let fresh = BackupsScreenStatusRules.status(
            of: targets, games: [games[0]], lastSuccessText: "on 4 March")
        XCTAssertEqual(fresh?.line, "All games backed up")
    }

    func testATargetProblemOutranksLateGames() {
        let targets = [
            TargetRowFacts(descriptor: target(id: "a", label: "Dropbox"), failure: .needsSignIn)
        ]
        let games = [
            GameFreshness(
                gameKey: "g1", level: .banner, targetId: "a", cause: .needsSignIn,
                unprotectedSince: failedAt)
        ]
        let status = BackupsScreenStatusRules.status(of: targets, games: games)
        XCTAssertEqual(status?.line, "Check Dropbox")
    }

    func testAScreenWithNoTargetCarriesNoStatusLine() {
        XCTAssertNil(BackupsScreenStatusRules.status(of: []))
    }

    func testEveryTargetPausedSaysSo() {
        let targets = [
            TargetRowFacts(descriptor: target(id: "a", isPaused: true)),
            TargetRowFacts(descriptor: target(id: "b", isPaused: true)),
        ]
        XCTAssertEqual(
            BackupsScreenStatusRules.status(of: targets)?.line,
            BackupsScreenStatusRules.everythingPausedLine)
    }

    // MARK: - 3 and 4. Usage

    func testATargetWithNoSpaceQueryShowsTheBytesItWrote() {
        let usage = TargetUsageRules.usage(
            reading: nil, capBytes: nil, bytesWrittenHere: 2_400_000_000)
        XCTAssertEqual(usage, .bytesWritten(2_400_000_000))
        XCTAssertEqual(
            TargetUsageRules.line(usage, usedText: "2.4 GB"),
            "2.4 GB backed up here. This service doesn't show how much free space is left.")
        XCTAssertEqual(
            TargetUsageRules.line(.bytesWritten(0), usedText: "Zero KB"),
            "Nothing backed up here yet. This service doesn't show how much free space is left.")
    }

    func testATargetThatAnsweredOnceAndStoppedFallsBackWithNoError() {
        let answered = TargetUsageRules.usage(
            reading: QuotaReading(usedBytes: 400, limitBytes: 1_000), capBytes: nil,
            bytesWrittenHere: 250)
        XCTAssertEqual(answered, .bar(usedBytes: 400, limitBytes: 1_000))

        let stopped = TargetUsageRules.usage(
            reading: nil, capBytes: nil, bytesWrittenHere: 250)
        XCTAssertEqual(stopped, .bytesWritten(250))
    }

    func testACapGovernsTheBarAndCountsTheBytesEmpoWrote() {
        let usage = TargetUsageRules.usage(
            reading: QuotaReading(usedBytes: 900, limitBytes: 5_000), capBytes: 1_000,
            bytesWrittenHere: 250)
        XCTAssertEqual(usage, .bar(usedBytes: 250, limitBytes: 1_000))
    }

    // MARK: - 5. Removing a target

    func testRemoveRefusesACheckedDeleteBoxOnAnUnreachableTarget() {
        let unreachable = target(label: "Dropbox")
        let answer = TargetRemovalRules.answer(
            deleteBackups: true, state: .unreachable(at: failedAt), target: unreachable)
        guard case .refuse(let refusal) = answer else {
            return XCTFail("a checked box on an unreachable target must refuse")
        }
        XCTAssertEqual(
            refusal.line, "Empo can't delete the backups while it can't connect to Dropbox.")
        XCTAssertEqual(refusal.actions, [.removeWithoutDeleting, .cancel])
        XCTAssertEqual(refusal.actions.count, 2)
    }

    func testAnUncheckedBoxRemovesEvenWhenTheTargetIsUnreachable() {
        XCTAssertEqual(
            TargetRemovalRules.answer(
                deleteBackups: false, state: .unreachable(at: failedAt), target: target()),
            .remove)
    }

    func testTheConfirmButtonMatchesTheBox() {
        let reachable = target()
        XCTAssertEqual(
            TargetRemovalRules.sheet(target: reachable, deleteBackups: false).confirmLabel,
            "Remove")
        let checked = TargetRemovalRules.sheet(
            target: reachable, deleteBackups: true, deviceName: "this iPhone")
        XCTAssertEqual(checked.confirmLabel, "Remove and delete")
        XCTAssertEqual(checked.title, "Remove Dropbox?")
        XCTAssertEqual(checked.deleteLabel, "Also delete this iPhone's backups on Dropbox")
        XCTAssertTrue(checked.body.hasSuffix("You can't undo this."), checked.body)
        XCTAssertFalse(
            TargetRemovalRules.sheet(target: reachable, deleteBackups: false).body
                .contains("undo"))
    }

    // MARK: - 6 and 7. The namespace list

    private func namespace(
        id: String = "ns-1", device: String = "Old iPhone", snapshots: Int = 34, games: Int = 3,
        isThisDevice: Bool = false, isEarlierSpace: Bool = false
    ) -> BackupNamespaceRow {
        BackupNamespaceRow(
            namespaceId: id, deviceName: device, snapshotCount: snapshots, gameCount: games,
            totalBytes: 1_000, isThisDevice: isThisDevice, isEarlierSpace: isEarlierSpace)
    }

    func testThisDeviceNamespaceIsMarkedAndOffersNoDelete() {
        let mine = namespace(device: "Sam's iPhone", isThisDevice: true)
        XCTAssertFalse(NamespaceListRules.canDelete(mine))
        XCTAssertNil(
            NamespaceListRules.confirmation(for: mine, dateRangeText: "March"))
        XCTAssertTrue(NamespaceListRules.canDelete(namespace()))
    }

    func testANamespaceLeftByASplitNamesItself() {
        XCTAssertEqual(
            NamespaceListRules.title(of: namespace(isEarlierSpace: true)),
            "This device, older backups")
    }

    func testTheDestructiveButtonNamesTheExactSnapshotCount() {
        let confirmation = NamespaceListRules.confirmation(
            for: namespace(snapshots: 34, games: 5),
            dateRangeText: "4 March to 2 August 2026")
        XCTAssertEqual(confirmation?.buttonLabel, "Delete 34 backups")
        XCTAssertEqual(
            confirmation?.lines, ["Old iPhone", "5 games", "34 backups", "4 March to 2 August 2026"])
        XCTAssertEqual(
            confirmation?.spaceLine,
            "Empo deletes these backups from the location now. You can't undo this. Your other backups stay.")
    }

    func testTheDestructiveButtonCountsOneSnapshotInTheSingular() {
        XCTAssertEqual(
            NamespaceListRules.confirmation(
                for: namespace(snapshots: 1, games: 1), dateRangeText: "2 August 2026"
            )?.buttonLabel,
            "Delete 1 backup")
    }

    // MARK: - 8. The notification sheet

    func testNotNowMarksNothingAndNeverReturnsByItself() {
        let effect = BackupNotificationAsk.effect(of: .notNow)
        XCTAssertFalse(effect.showsTheSystemPrompt)
        XCTAssertFalse(effect.marksThePromptSpent)
        XCTAssertFalse(effect.showsTheSheetAgain)
    }

    func testTurnOnSpendsTheOneChanceAtTheSystemPrompt() {
        let effect = BackupNotificationAsk.effect(of: .turnOn)
        XCTAssertTrue(effect.showsTheSystemPrompt)
        XCTAssertTrue(effect.marksThePromptSpent)
        XCTAssertFalse(effect.showsTheSheetAgain)
    }

    func testTheRowAsksAgainUntilTheSystemStopsAllowingIt() {
        XCTAssertEqual(
            BackupNotificationAsk.rowAction(systemMayStillPrompt: true), .showTheSystemPrompt)
        XCTAssertEqual(
            BackupNotificationAsk.rowAction(systemMayStillPrompt: false), .openTheSettingsApp)
    }

    // MARK: - The run stop that leaves the failure

    func testARunStopLeavesTheFailureTheRowShows() {
        XCTAssertEqual(TargetFailure.of(.needsSignIn), .needsSignIn)
        XCTAssertEqual(
            TargetFailure.of(.blocked(reason: "no write right")),
            .blockedByPermissions(reason: "no write right"))
        XCTAssertEqual(TargetFailure.of(.full(reason: "no room")), .full(reason: "no room"))
        XCTAssertEqual(TargetFailure.of(.offline), .unreachable(.noAnswer))
        XCTAssertEqual(TargetFailure.of(.serverError(status: 500)), .unreachable(.serverError))
        XCTAssertEqual(TargetFailure.of(.throttled(retryAfter: 30)), .unreachable(.busy))
        XCTAssertEqual(
            TargetFailure.of(.rejected(message: "refused")), .rejected(message: "refused"))
        XCTAssertNil(TargetFailure.of(.readOnlyFormat(.unreadableFormat)))
    }
}
