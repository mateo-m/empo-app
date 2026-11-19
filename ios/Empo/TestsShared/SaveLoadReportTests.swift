// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class SaveLoadReportTests: XCTestCase {
    private let load = ContinuousClock.now

    func testNoLoadGivesNone() {
        XCTAssertEqual(SaveLoad.never.tag(at: load), "none")
        XCTAssertNil(SaveLoad.never.seconds(at: load))
    }

    func testLoadUpToSixtySecondsAgoIsWithin() {
        XCTAssertEqual(SaveLoad.at(load).tag(at: load), "within_60s")
        XCTAssertEqual(SaveLoad.at(load).tag(at: load + .seconds(60)), "within_60s")
        XCTAssertEqual(SaveLoad.at(load).seconds(at: load + .seconds(12)), 12)
    }

    func testOlderLoadIsOver() {
        XCTAssertEqual(SaveLoad.at(load).tag(at: load + .milliseconds(60_001)), "over_60s")
        XCTAssertEqual(SaveLoad.at(load).seconds(at: load + .seconds(3600)), 3600)
    }

    func testRepairReportKeepsTheFaultWithoutTheFileName() {
        XCTAssertEqual(
            ErrorReports.saveRepairFault("Game_2.rxdata: the @name of an RPG::AudioFile was a Float"),
            "the @name of an RPG::AudioFile was a Float")
        XCTAssertEqual(
            ErrorReports.saveRepairFault("Save12.rvdata: the @name of an RPG::BGS was an Array"),
            "the @name of an RPG::BGS was an Array")
        XCTAssertEqual(
            ErrorReports.saveRepairFault("a: b.rxdata: the @name of an RPG::BGM was a Float"),
            "the @name of an RPG::BGM was a Float")
    }
}
