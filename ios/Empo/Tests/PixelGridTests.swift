// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class PixelGridTests: XCTestCase {
    func testEveryCornerHasTheSameStepsOnTheTopAndTheSide() {
        for count in 1...24 {
            let rows = PixelGrid.corner(count)
            let columns = (0..<count).map { column in rows.filter { $0 > column }.count }
            XCTAssertEqual(rows, columns, "corner of \(count) pixels")
        }
    }

    func testEveryCornerStepsInFromTheEdge() {
        for count in 1...24 {
            let rows = PixelGrid.corner(count)
            XCTAssertEqual(rows, rows.sorted(by: >), "corner of \(count) pixels")
            XCTAssertGreaterThan(rows.first ?? 0, 0, "corner of \(count) pixels")
        }
    }
}
