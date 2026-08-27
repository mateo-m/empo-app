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
                lastSweepAt: daysAgo(3), now: now, reading: nil, capBytes: nil),
            .notDue)
    }

    func testATargetThatNeverSweptIsOverdue() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: nil, now: now, reading: nil, capBytes: nil),
            .runOverdue)
    }

    func testATargetWithNoSpaceQueryHasOnlyTheCalendar() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: nil, capBytes: nil),
            .run)
    }

    func testASweepStaysQueuedWhileTheTargetReportsRoomToSpare() {
        // 70 percent of the quota is under the 80 percent mark, so
        // the calendar alone does not force the sweep.
        let reading = QuotaReading(usedBytes: 700, limitBytes: 1_000)

        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: reading, capBytes: nil),
            .queued)
    }

    func testEightyPercentUsageForcesTheSweep() {
        let reading = QuotaReading(usedBytes: 800, limitBytes: 1_000)

        XCTAssertFalse(SweepSchedule.hasRoomToSpare(reading: reading, capBytes: nil))
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(8), now: now, reading: reading, capBytes: nil),
            .run)
    }

    func testTheCapMovesTheEightyPercentMark() {
        // 700 of 1000 leaves room to spare. Under a cap of 800 the
        // same 700 bytes are past the mark.
        let reading = QuotaReading(usedBytes: 700, limitBytes: 1_000)

        XCTAssertTrue(SweepSchedule.hasRoomToSpare(reading: reading, capBytes: nil))
        XCTAssertFalse(SweepSchedule.hasRoomToSpare(reading: reading, capBytes: 800))
    }

    func testPressureDoesNotOverrideTheCalendar() {
        let reading = QuotaReading(usedBytes: 990, limitBytes: 1_000)

        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(1), now: now, reading: reading, capBytes: nil),
            .notDue)
    }

    func testThirtyDaysMakesTheSweepOverdue() {
        XCTAssertEqual(
            SweepSchedule.decide(
                lastSweepAt: daysAgo(31), now: now, reading: nil, capBytes: nil),
            .runOverdue)
    }
}
