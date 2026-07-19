import XCTest

@testable import GameProbe

final class KeyCodeTableTests: XCTestCase {

    func testScancodeAnchorsMatchMkxp() {
        let anchors: [(String, Int32)] = [
            ("KeyA", 4),
            ("Digit1", 30),
            ("Enter", 40),
            ("Space", 44),
            ("ArrowRight", 79),
            ("ArrowLeft", 80),
            ("ArrowDown", 81),
            ("ArrowUp", 82),
            ("Home", 74),
            ("ControlLeft", 224),
            ("ShiftLeft", 225),
            ("AltLeft", 226),
        ]
        for (code, expected) in anchors {
            XCTAssertEqual(KeyCodeTable.scancode(for: code), expected, code)
            XCTAssertEqual(KeyCodeTable.code(for: expected), code)
        }
    }

    func testAllCodesStableOrder() {
        XCTAssertEqual(KeyCodeTable.allCodes.first, "KeyA")
        XCTAssertEqual(KeyCodeTable.allCodes.last, "MetaRight")
        XCTAssertEqual(KeyCodeTable.allCodes.count, 106)
    }

    func testDisplayNamesForLettersAndDigits() {
        XCTAssertEqual(KeyCodeTable.displayName(for: "KeyZ"), "Z")
        XCTAssertEqual(KeyCodeTable.displayName(for: "Digit5"), "5")
        XCTAssertEqual(KeyCodeTable.displayName(for: "ShiftLeft"), "⇧")
        XCTAssertEqual(KeyCodeTable.displayName(for: "F5"), "F5")
        XCTAssertEqual(KeyCodeTable.displayName(for: "ArrowUp"), "↑")
        XCTAssertEqual(KeyCodeTable.displayName(for: "Enter"), "↵")
        XCTAssertEqual(KeyCodeTable.displayName(for: "Space"), "Space")
    }

    func testUnknownCodeReturnsNil() {
        XCTAssertNil(KeyCodeTable.scancode(for: "NotAKey"))
        XCTAssertNil(KeyCodeTable.displayName(for: "NotAKey"))
    }
}
