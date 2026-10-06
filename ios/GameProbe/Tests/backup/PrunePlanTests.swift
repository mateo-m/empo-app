import Foundation
import XCTest

@testable import GameProbe

/// The prune of SPEC 5.10 over the snapshot ledger, plus the one-off
/// rule of 5.15.
final class PrunePlanTests: XCTestCase {

    /// Midnight UTC, so a run of hourly snapshots stays inside one
    /// day bucket and the daily rung adds nothing to the last rung.
    private let start = Date(timeIntervalSince1970: 1_699_920_000)

    private func entry(
        hoursAfterStart hours: Double, isOneOff: Bool = false
    ) -> SnapshotLedgerEntry {
        let date = start.addingTimeInterval(hours * 3_600)
        return SnapshotLedgerEntry(
            targetId: "t1", gameKey: "g1",
            snapshotId: BackupKeys.snapshotId(
                date: date, suffix: String(format: "%06d", Int(hours))),
            createdAt: date,
            isOneOff: isOneOff)
    }

    func testAGameWithNoLocalContainerKeepsThree() {
        XCTAssertEqual(PrunePlan.kind(hasLocalContainer: false), .gameWithoutContainer)
        XCTAssertEqual(PrunePlan.kind(hasLocalContainer: true), .game)
    }

    func testTheLadderGovernsTheOrdinarySnapshots() {
        let ledger = (0..<12).map { entry(hoursAfterStart: Double($0)) }
        let plan = PrunePlan.plan(ledger: ledger, kind: .game, preset: .standard)

        // Twelve snapshots inside one day. The last rung of the
        // standard game ladder keeps 10, and the daily and weekly
        // rungs hold one bucket each, which the last rung already
        // covers.
        XCTAssertEqual(plan.keep.count, 10)
        XCTAssertEqual(
            plan.drop,
            [ledger[0].snapshotId, ledger[1].snapshotId].sorted())
    }

    func testTheAnswerMatchesRetentionPolicyWhenNoSnapshotIsAOneOff() {
        let ledger = (0..<12).map { entry(hoursAfterStart: Double($0)) }
        let dated = ledger.map { DatedSnapshot(id: $0.snapshotId, date: $0.createdAt) }

        XCTAssertEqual(
            PrunePlan.plan(ledger: ledger, kind: .game, preset: .standard),
            RetentionPolicy.plan(for: dated, kind: .game, preset: .standard))
    }

    func testAOneOffKeepsItsOwnRetentionRuleOfOne() {
        // The one-off sits outside the ladder, so 12 ordinary
        // snapshots cannot push it out.
        var ledger = (0..<12).map { entry(hoursAfterStart: Double($0) + 10) }
        let oneOff = entry(hoursAfterStart: 0, isOneOff: true)
        ledger.append(oneOff)

        let plan = PrunePlan.plan(ledger: ledger, kind: .game, preset: .standard)

        XCTAssertTrue(plan.keep.contains(oneOff.snapshotId))
        XCTAssertFalse(plan.drop.contains(oneOff.snapshotId))
    }

    func testOnlyTheNewestOneOffSurvives() {
        let older = entry(hoursAfterStart: 1, isOneOff: true)
        let newer = entry(hoursAfterStart: 2, isOneOff: true)
        let plan = PrunePlan.plan(ledger: [older, newer], kind: .game, preset: .standard)

        XCTAssertEqual(plan.keep, [newer.snapshotId])
        XCTAssertEqual(plan.drop, [older.snapshotId])
    }

    func testAOneOffDoesNotSpendARungOfTheLadder() {
        // Ten ordinary snapshots fill the last rung. The one-off is
        // extra, and all 11 stay.
        var ledger = (0..<10).map { entry(hoursAfterStart: Double($0) + 10) }
        ledger.append(entry(hoursAfterStart: 0, isOneOff: true))

        let plan = PrunePlan.plan(ledger: ledger, kind: .game, preset: .standard)

        XCTAssertEqual(plan.keep.count, 11)
        XCTAssertTrue(plan.drop.isEmpty)
    }

    func testAnEmptyLedgerDropsNothing() {
        let plan = PrunePlan.plan(ledger: [], kind: .preferences, preset: .standard)

        XCTAssertTrue(plan.keep.isEmpty)
        XCTAssertTrue(plan.drop.isEmpty)
    }
}
