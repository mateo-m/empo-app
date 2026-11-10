// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class RescuedRubyErrorTests: XCTestCase {

    func testInsurgenceCorruptSaveMessageIsAnError() {
        let text =
            #"[EOFError, "end of file reached", ["059:SpriteWindow:2145:in `oldload'", "114:PokemonLoad:447:in `pbStartLoadScreen'"]]"#
        XCTAssertEqual(
            RescuedRubyError(text),
            RescuedRubyError(className: "EOFError", message: "end of file reached"))
    }

    func testInspectedExceptionIsAnError() {
        XCTAssertEqual(
            RescuedRubyError("#<Errno::ENOENT: No such file or directory - Data/Map150.rxdata>"),
            RescuedRubyError(
                className: "Errno::ENOENT", message: "No such file or directory - Data/Map150.rxdata"))
    }

    func testEscapedQuoteStaysInTheMessage() {
        XCTAssertEqual(
            RescuedRubyError(#"[NoMethodError, "undefined method `x' for \"a\":String", []]"#)?.message,
            #"undefined method `x' for \"a\":String"#)
    }

    func testMessageKeepsEveryAngleBracket() {
        XCTAssertEqual(
            RescuedRubyError("#<NoMethodError: undefined method `>' for #<Game_Player:0x00007f3a>>")?.message,
            "undefined method `>' for #<Game_Player:0x00007f3a>")
    }

    func testAddressesDoNotSplitTheIssue() {
        XCTAssertEqual(
            RescuedRubyError(className: "NoMethodError", message: "for #<Game_Player:0x00007f3a>")
                .fingerprint,
            RescuedRubyError(className: "NoMethodError", message: "for #<Game_Player:0x0000beef>").fingerprint
        )
    }

    func testNormalGameMessagesAreNotErrors() {
        XCTAssertNil(RescuedRubyError("Saved the game."))
        XCTAssertNil(RescuedRubyError(#"[Pikachu, "Lv. 5"]"#))
        XCTAssertNil(RescuedRubyError("#<Game_Character: 0x1234>"))
        XCTAssertNil(RescuedRubyError("Error: EOFError"))
    }
}
