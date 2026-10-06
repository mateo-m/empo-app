import Foundation
import XCTest

@testable import GameProbe

/// The force-quit rule of SPEC 7.10.
final class InterruptedRunTallyTests: XCTestCase {

    func testTheFirstTwoLostRunsSayNothing() {
        var tally = InterruptedRunTally()
        for _ in 1...2 {
            tally.record(.interrupted)
            XCTAssertNil(tally.cause(level: .stale))
        }
    }

    func testThreeLostRunsPastTheSevenDayMarkNameTheHabit() {
        var tally = InterruptedRunTally()
        for _ in 1...3 { tally.record(.interrupted) }
        XCTAssertEqual(tally.count, 3)
        XCTAssertEqual(tally.cause(level: .stale), .runsInterrupted)
        XCTAssertEqual(
            StaleCause.runsInterrupted.line(targetLabel: nil), ForceQuitRule.habitLine)
    }

    func testThreeLostRunsBeforeTheSevenDayMarkStaySilent() {
        var tally = InterruptedRunTally()
        for _ in 1...3 { tally.record(.interrupted) }
        XCTAssertNil(tally.cause(level: .fresh))
    }

    func testASuccessfulRunResetsTheCount() {
        var tally = InterruptedRunTally()
        for _ in 1...3 { tally.record(.interrupted) }
        tally.record(.succeeded)
        XCTAssertEqual(tally.count, 0)
        XCTAssertNil(tally.cause(level: .banner))
    }

    func testAFailureTheProcessSurvivedNeitherCountsNorClears() {
        var tally = InterruptedRunTally()
        tally.record(.interrupted)
        tally.record(.otherFailure)
        XCTAssertEqual(tally.count, 1)
    }

    func testRecordingReturnsACopyAndLeavesTheOriginal() {
        let tally = InterruptedRunTally(count: 2)
        XCTAssertEqual(tally.recording(.interrupted).count, 3)
        XCTAssertEqual(tally.count, 2)
    }
}
