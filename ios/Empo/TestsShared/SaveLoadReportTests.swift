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

    func testRejectedSavesOfOneFaultShareAnIssue() {
        XCTAssertEqual(
            ErrorReports.saveRejectedFingerprint("bytes 4 to 1800 do not read back as a dump"),
            ErrorReports.saveRejectedFingerprint("bytes 0 to 95 do not read back as a dump"))
        XCTAssertEqual(
            ErrorReports.saveRejectedFingerprint("the @name of an RPG::AudioFile is a Float"),
            ["save-rejected", "the @name of an RPG::AudioFile is a Float"])
    }
}
