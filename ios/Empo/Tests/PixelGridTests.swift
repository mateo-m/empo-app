// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI
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

    func testEveryShapeReachesAllFourSides() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let radii: [CGFloat] = [0, Radius.xs, Radius.sm, Radius.md, .infinity]
        for topLeading in radii {
            for bottomTrailing in radii {
                let shape = PixelRect(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: topLeading, bottomLeading: Radius.xs,
                        bottomTrailing: bottomTrailing, topTrailing: Radius.xs))
                let path = shape.path(in: rect)
                XCTAssertEqual(path.boundingRect, rect, "corners \(topLeading) and \(bottomTrailing)")
                XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 1, y: rect.midY)))
                XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 1, y: rect.midY)))
            }
        }
    }
}
