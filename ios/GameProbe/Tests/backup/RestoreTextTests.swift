import XCTest

@testable import GameProbe

final class RestoreTextTests: XCTestCase {

    func testAFinishedRestoreSaysSo() {
        XCTAssertEqual(RestoreNotices.line(of: .finished(RestoreResult())), "Restored.")
        XCTAssertEqual(
            RestoreNotices.line(of: .finished(RestoreResult(partialPathCount: 1))),
            "Restored. 1 file was being written when this backup ran. "
                + "Empo restored it as it was then.")
    }

    func testEveryStopSaysWhatToDoNext() {
        let outcomes: [RestoreOutcome] =
            RestoreStopReason.allCases.map { .stopped($0, RestoreResult()) } + [
                .notEnoughSpace(.init(neededBytes: 2_000_000, freeBytes: 1_000_000)),
                .failed(RestoreNotices.unreadableLine),
            ]
        for outcome in outcomes {
            let line = RestoreNotices.line(of: outcome)
            XCTAssertTrue(line.first?.isUppercase ?? false, line)
            XCTAssertTrue(line.hasSuffix("."), line)
            XCTAssertGreaterThan(line.split(separator: ".").count, 1, line)
        }
    }

    func testAUserCancelIsNotAGameLaunch() {
        XCTAssertEqual(
            RestoreNotices.line(of: .stopped(.cancelled, RestoreResult())),
            "You stopped the restore. The files it already restored stay.")
    }
}
