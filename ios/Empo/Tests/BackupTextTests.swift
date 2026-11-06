import XCTest

@testable import Empo

final class BackupTextTests: XCTestCase {

    func testARangeInsideOneDayNamesTheDayOnce() {
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9))!
        let evening = morning.addingTimeInterval(10 * 3_600)
        let day = morning.formatted(.dateTime.day().month(.wide).year())

        XCTAssertEqual(BackupText.range(from: morning, to: evening), day)
    }

    func testARangeOverTwoDaysNamesBoth() {
        let first = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9))!
        let last = first.addingTimeInterval(86_400)

        XCTAssertNotEqual(
            BackupText.range(from: first, to: last),
            last.formatted(.dateTime.day().month(.wide).year()))
    }
}
