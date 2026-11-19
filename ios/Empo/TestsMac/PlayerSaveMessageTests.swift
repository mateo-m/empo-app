// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class PlayerSaveMessageTests: XCTestCase {
    private func decode(_ line: String) throws -> PlayerMessage {
        try JSONDecoder().decode(PlayerMessage.self, from: Data(line.utf8))
    }

    func testSaveLoadedLineDecodes() throws {
        guard case .saveLoaded = try decode(#"{"saveLoaded":{}}"#) else {
            return XCTFail("not a save load")
        }
    }

    func testSaveRepairedLineKeepsTheDetail() throws {
        let line = #"{"saveRepaired":{"_0":"Game_2.rxdata: the @name of an RPG::AudioFile was a Float"}}"#
        guard case .saveRepaired(let detail) = try decode(line) else {
            return XCTFail("not a repaired save")
        }
        XCTAssertEqual(detail, "Game_2.rxdata: the @name of an RPG::AudioFile was a Float")
    }
}
