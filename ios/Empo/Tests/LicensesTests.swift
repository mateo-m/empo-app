// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class LicensesTests: XCTestCase {
    /// The additional terms of each engine ask for its attribution on
    /// this screen.
    func testEveryCoreShowsTheNoticeOfItsEngine() {
        let names = Set(LicenseEntry.inThisBuild().map(\.name))
        XCTAssertTrue(names.contains("Empo"))
        for core in GameCores.inThisBuild {
            let engine =
                switch core.framework {
                case "MkxpCore": "mkxp-z-apple-mobile"
                case "MvmzCore": "mvmz-apple-mobile"
                default: "psdk-apple-mobile"
                }
            XCTAssertTrue(names.contains(engine), "\(core.framework).framework shows no \(engine) notice")
        }
    }

    func testTheListLoadsQuickly() {
        measure { _ = LicenseEntry.inThisBuild() }
    }

    func testUnwrappedJoinsTheLinesOfAParagraph() {
        let text = """
            Copyright (c) 2002 Someone
            Copyright (c) 2003 Someone Else

            Permission is granted to anyone
              to use this software.

            1. The first condition
               goes on here.
            2. The second one.
            ------------------
            (a) An item.

            Name      Value
            Other     More
            """
        XCTAssertEqual(
            LicenseEntry.unwrapped(text),
            """
            Copyright (c) 2002 Someone
            Copyright (c) 2003 Someone Else

            Permission is granted to anyone to use this software.

            1. The first condition goes on here.
            2. The second one.
            ------------------
            (a) An item.

            Name      Value
            Other     More
            """)
    }

    func testMergedShowsEachNameOnceWithEachDistinctText() {
        let merged = LicenseEntry.merged([
            LicenseEntry("zlib", license: "zlib License", text: "A"),
            LicenseEntry("Ruby", license: "Ruby License", text: "B"),
            LicenseEntry("ruby gem", license: "MIT", text: "C"),
            LicenseEntry("Ruby", license: "Ruby License", text: "B"),
            LicenseEntry("Ruby", license: "Ruby License", text: "D"),
        ])
        XCTAssertEqual(merged.map(\.name), ["Ruby", "ruby gem", "zlib"])
        XCTAssertEqual(merged[0].text, "B\n\n* * *\n\nD")
    }
}
