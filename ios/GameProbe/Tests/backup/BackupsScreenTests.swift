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
            TargetRowFacts(descriptor: target(), reach: .accountOff),
            TargetRowFacts(descriptor: target(accountHint: nil)),
            TargetRowFacts(descriptor: target(isPaused: true)),
            TargetRowFacts(descriptor: target(), failure: .needsSignIn),
            TargetRowFacts(
                descriptor: target(), failure: .blockedByPermissions(reason: "no write right")),
            TargetRowFacts(descriptor: target(), failure: .rejected(message: "too big")),
            TargetRowFacts(descriptor: target(), failure: .full(reason: "no room")),
            TargetRowFacts(descriptor: target(), failure: .unreachable, failedAt: failedAt),
            TargetRowFacts(descriptor: target()),
        ]
    }

    // MARK: - 1. The nine states, highest first

    func testEveryPairOfStatesKeepsTheOrderOfTheSpec() {
        let states = factsInRankOrder().map(TargetRowRules.state(of:))
        XCTAssertEqual(states.map(\.rank), Array(1...9))
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
                reach: .accountOff))
        XCTAssertEqual(row.title, "iCloud Drive")
        XCTAssertEqual(row.stateLine, TargetRowRules.iCloudOffLine)
        XCTAssertNil(row.action)
        XCTAssertTrue(row.isDisabled)
    }

    func testTheUnreachableLineReadsAsAPastEventWithATime() {
        let row = TargetRowRules.row(
            TargetRowFacts(
                descriptor: target(label: "Homelab", accountHint: "homelab.lan"),
                failure: .unreachable, failedAt: failedAt),
            time: "14:03")
        XCTAssertEqual(row.stateLine, "Could not reach homelab.lan at 14:03")
        XCTAssertNil(row.action)
    }

    func testAForegroundOnlyTargetCarriesThePermanentLine() {
        let row = TargetRowRules.row(
            TargetRowFacts(descriptor: target(), supportsBackgroundTransfer: false))
        XCTAssertEqual(row.foregroundOnlyLine, "Backs up only while Empo is open")
    }

    // MARK: - 2. The status line

    private func row(_ facts: TargetRowFacts) -> TargetRow {
        TargetRowRules.row(facts, time: "14:03")
    }

    func testTheStatusLineNamesTheWorstEnabledTargetOfThree() {
        let rows = [
            row(TargetRowFacts(descriptor: target(id: "a", label: "Homelab"))),
            row(
                TargetRowFacts(
                    descriptor: target(id: "b", label: "Dropbox"), failure: .needsSignIn)),
            row(
                TargetRowFacts(
                    descriptor: target(id: "c", label: "S3"), failure: .full(reason: "no room"))),
        ]
        let status = BackupsScreenStatusRules.status(rows: rows)
        XCTAssertEqual(status?.line, "Dropbox needs you to sign in again")
        XCTAssertEqual(status?.targetId, "b")
        XCTAssertEqual(status?.isHealthy, false)
    }

    func testAPausedTargetLeavesTheStatusComputation() {
        let rows = [
            row(
                TargetRowFacts(
                    descriptor: target(id: "a", label: "Dropbox", isPaused: true),
                    failure: .needsSignIn)),
            row(TargetRowFacts(descriptor: target(id: "b", label: "Homelab"))),
        ]
        let status = BackupsScreenStatusRules.status(rows: rows, lastSuccessText: "today")
        XCTAssertEqual(status?.line, "All games backed up today")
        XCTAssertTrue(status?.isHealthy == true)
    }

    func testAScreenWithNoTargetCarriesNoStatusLine() {
        XCTAssertNil(BackupsScreenStatusRules.status(rows: []))
    }

    func testEveryTargetPausedSaysSo() {
        let rows = [
            row(TargetRowFacts(descriptor: target(id: "a", isPaused: true))),
            row(TargetRowFacts(descriptor: target(id: "b", isPaused: true))),
        ]
        XCTAssertEqual(
            BackupsScreenStatusRules.status(rows: rows)?.line,
            BackupsScreenStatusRules.everythingPausedLine)
    }

    // MARK: - 3 and 4. Usage

    func testATargetWithNoSpaceQueryShowsTheBytesItWrote() {
        let usage = TargetUsageRules.usage(
            reading: nil, capBytes: nil, bytesWrittenHere: 2_400_000_000)
        XCTAssertEqual(usage, .bytesWritten(2_400_000_000))
        XCTAssertEqual(
            TargetUsageRules.line(usage, usedText: "2.4 GB"),
            "2.4 GB backed up here. This service does not report free space.")
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
            refusal.line, "Empo cannot delete the backups while Dropbox is unreachable.")
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
    }

    // MARK: - 6 and 7. The namespace list

    private func namespace(
        id: String = "ns-1", device: String = "Old iPhone", snapshots: Int = 34,
        isThisDevice: Bool = false, isEarlierSpace: Bool = false
    ) -> BackupNamespaceRow {
        BackupNamespaceRow(
            namespaceId: id, deviceName: device, snapshotCount: snapshots,
            totalBytes: 1_000, isThisDevice: isThisDevice, isEarlierSpace: isEarlierSpace)
    }

    func testThisDeviceNamespaceIsMarkedAndOffersNoDelete() {
        let mine = namespace(device: "Sam's iPhone", isThisDevice: true)
        XCTAssertFalse(NamespaceListRules.canDelete(mine))
        XCTAssertNil(
            NamespaceListRules.confirmation(for: mine, gameCount: 3, dateRangeText: "March"))
        XCTAssertTrue(NamespaceListRules.canDelete(namespace()))
    }

    func testANamespaceLeftByASplitNamesItself() {
        XCTAssertEqual(
            NamespaceListRules.title(of: namespace(isEarlierSpace: true)),
            "This device, earlier space")
    }

    func testTheDestructiveButtonNamesTheExactSnapshotCount() {
        let confirmation = NamespaceListRules.confirmation(
            for: namespace(snapshots: 34), gameCount: 5,
            dateRangeText: "4 March to 2 August 2026")
        XCTAssertEqual(confirmation?.buttonLabel, "Delete 34 snapshots")
        XCTAssertEqual(
            confirmation?.lines, ["Old iPhone", "5 games", "34 snapshots", "4 March to 2 August 2026"])
        XCTAssertEqual(confirmation?.spaceLine, "The space returns on the next sweep.")
    }

    func testTheDestructiveButtonCountsOneSnapshotInTheSingular() {
        XCTAssertEqual(
            NamespaceListRules.confirmation(
                for: namespace(snapshots: 1), gameCount: 1, dateRangeText: "2 August 2026"
            )?.buttonLabel,
            "Delete 1 snapshot")
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
        XCTAssertEqual(TargetFailure.of(.offline), .unreachable)
        XCTAssertEqual(
            TargetFailure.of(.rejected(message: "refused")), .rejected(message: "refused"))
        XCTAssertNil(TargetFailure.of(.readOnlyFormat(.unreadableFormat)))
    }
}
