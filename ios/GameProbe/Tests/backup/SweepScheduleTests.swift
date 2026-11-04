import Foundation
import XCTest

@testable import GameProbe

/// When the mark-and-sweep of SPEC 5.11 may run.
final class SweepScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    func testTheCalendarMarksAreSevenAndThirtyDays() {
        XCTAssertEqual(SweepSchedule.dueAfter, 7 * 86_400)
        XCTAssertEqual(SweepSchedule.overdueAfter, 30 * 86_400)
    }

    func testASweepIsNotDueBeforeSevenDays() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(3), now: now, reading: nil, capBytes: nil, storedBytes: 0),
            .notDue)
    }

    func testATargetThatNeverSweptIsOverdue() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: nil, now: now, reading: nil, capBytes: nil, storedBytes: 0),
            .runOverdue)
    }

    func testATargetWithNoSpaceQueryHasOnlyTheCalendar() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: nil, capBytes: nil, storedBytes: 0),
            .run)
    }

    func testASweepStaysQueuedWhileTheTargetReportsRoomToSpare() {
        // 70 percent of the quota is under the 80 percent mark, so
        // the calendar alone does not force the sweep.
        let reading = QuotaReading(usedBytes: 700, limitBytes: 1_000)

        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: reading, capBytes: nil, storedBytes: 0),
            .queued)
    }

    func testEightyPercentUsageForcesTheSweep() {
        let reading = QuotaReading(usedBytes: 800, limitBytes: 1_000)

        XCTAssertFalse(SweepSchedule.hasRoomToSpare(reading: reading, capBytes: nil, storedBytes: 0))
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: reading, capBytes: nil, storedBytes: 0),
            .run)
    }

    func testTheCapCountsEmposOwnBytes() {
        // The account holds 700 of 1000, mostly files that are not
        // Empo's. Empo's 100 bytes are far from a cap of 800, and its
        // 700 bytes are past the mark.
        let reading = QuotaReading(usedBytes: 700, limitBytes: 1_000)

        XCTAssertTrue(
            SweepSchedule.hasRoomToSpare(reading: reading, capBytes: 800, storedBytes: 100))
        XCTAssertFalse(
            SweepSchedule.hasRoomToSpare(reading: reading, capBytes: 800, storedBytes: 700))
    }

    func testTheCapForcesTheSweepOnATargetWithNoSpaceQuery() {
        XCTAssertTrue(SweepSchedule.hasRoomToSpare(reading: nil, capBytes: 1_000, storedBytes: 100))
        XCTAssertFalse(
            SweepSchedule.hasRoomToSpare(reading: nil, capBytes: 1_000, storedBytes: 900))
    }

    func testPressureDoesNotOverrideTheCalendar() {
        let reading = QuotaReading(usedBytes: 990, limitBytes: 1_000)

        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(1), now: now, reading: reading, capBytes: nil, storedBytes: 0),
            .notDue)
    }

    func testThirtyDaysMakesTheSweepOverdue() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(31), now: now, reading: nil, capBytes: nil, storedBytes: 0),
            .runOverdue)
    }
}
