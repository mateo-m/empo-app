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

    func testCommonKeysAlsoAppearInNaturalGroup() {
        let grouped = KeyCodeTable.codesByPickerGroup
        XCTAssertTrue(grouped[.letters]?.contains("KeyZ") == true)
        XCTAssertTrue(grouped[.modifiers]?.contains("ShiftLeft") == true)
        XCTAssertTrue(grouped[.function]?.contains("F5") == true)
    }

    func testLettersGroupIsCompleteAlphabet() {
        XCTAssertEqual(KeyCodeTable.codesByPickerGroup[.letters]?.count, 26)
    }

    func testSymbolsGroupedSeparatelyFromNavigation() {
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "Comma"), .symbols)
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "IntlYen"), .symbols)
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "ArrowUp"), .navigation)
        XCTAssertEqual(KeyCodeTable.pickerGroup(for: "Home"), .navigation)
    }

    func testAllCodesCoveredWithoutLoss() {
        let grouped = KeyCodeTable.codesByPickerGroup
        let flat = KeyCodePickerGroup.allCases.flatMap { grouped[$0] ?? [] }
        XCTAssertEqual(Set(flat), Set(KeyCodeTable.allCodes))
    }
}
