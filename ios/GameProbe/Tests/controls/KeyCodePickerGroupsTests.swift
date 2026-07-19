import XCTest

@testable import GameProbe

final class KeyCodePickerGroupsTests: XCTestCase {

    func testCommonKeysGroupedTogether() {
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "Enter"), .common)
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "KeyZ"), .common)
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "F5"), .common)
    }

    func testNonCommonLetterInLettersGroup() {
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "KeyB"), .letters)
    }

    func testAllCodesPartitionedWithoutLoss() {
        let grouped = KeyCodeTable.codesByPickerGroup
        let flat = KeyCodePickerGroup.allCases.flatMap { grouped[$0] ?? [] }
        XCTAssertEqual(Set(flat), Set(KeyCodeTable.allCodes))
        XCTAssertEqual(flat.count, KeyCodeTable.allCodes.count)
    }
}
