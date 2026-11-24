// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class ScreenRateTests: XCTestCase {
    func testAGameThat60HzShowsEvenlyNeedsNo120Hz() {
        for gameRate: Int32 in [60, 30, 20, 15] {
            XCTAssertFalse(EmpoGameNeeds120Hz(gameRate), "\(gameRate) frames per second")
        }
    }

    func testAGameThat60HzCannotShowEvenlyNeeds120Hz() {
        for gameRate: Int32 in [40, 24, 45, 50, 80, 120, 144] {
            XCTAssertTrue(EmpoGameNeeds120Hz(gameRate), "\(gameRate) frames per second")
        }
    }

    func testAGameWithNoRateNeedsNo120Hz() {
        for gameRate: Int32 in [0, -1] {
            XCTAssertFalse(EmpoGameNeeds120Hz(gameRate), "\(gameRate) frames per second")
        }
    }
}
