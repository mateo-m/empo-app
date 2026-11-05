// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

enum PixelGrid {
    /// The side of one pixel, in points. Every pixel shape uses it, so
    /// a chip and a card show pixels of the same size.
    static let step: CGFloat = 3

    /// How many pixels each row of a corner of `count` pixels leaves
    /// empty, from the outer edge in. A pixel is part of the shape when
    /// its center is inside the corner's circle, with a bias of 0.3
    /// pixels to the outside: a 3-pixel corner then gives a 2-step
    /// notch, and larger corners still read as round. The row test alone
    /// is not symmetric across the diagonal at some sizes (4, 5, 9 and
    /// up), so a pixel stays when the row test or its mirror keeps it.
    static func corner(_ count: Int) -> [Int] {
        guard count > 1 else { return Array(repeating: 1, count: count) }
        let n = Double(count)
        let rows = (0..<count).map { row in
            let dy = n - Double(row) - 0.5
            return Int((n - (n * n - dy * dy).squareRoot() + 0.3).rounded())
        }
        return rows.indices.map { row in min(rows[row], rows.count { $0 > row }) }
    }
}

/// A rectangle with corners drawn as pixel steps of `PixelGrid.step`.
/// A corner radius larger than half the short side gives a pixel
/// capsule, and a pixel circle on a square frame.
struct PixelRect: InsettableShape {
    var cornerRadii: RectangleCornerRadii
    var inset: CGFloat = 0

    init(cornerRadius: CGFloat) {
        cornerRadii = RectangleCornerRadii(
            topLeading: cornerRadius, bottomLeading: cornerRadius,
            bottomTrailing: cornerRadius, topTrailing: cornerRadius)
    }

    init(cornerRadii: RectangleCornerRadii) {
        self.cornerRadii = cornerRadii
    }

    func inset(by amount: CGFloat) -> PixelRect {
        var shape = self
        shape.inset += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let s = PixelGrid.step
        let most = Int(min(r.width, r.height) / 2 / s)
        func steps(_ radius: CGFloat) -> [CGFloat] {
            let count = radius.isFinite ? Int((radius / s).rounded()) : most
            return PixelGrid.corner(min(count, most)).map { CGFloat($0) * s }
        }
        let topLeading = steps(cornerRadii.topLeading)
        let topTrailing = steps(cornerRadii.topTrailing)
        let bottomTrailing = steps(cornerRadii.bottomTrailing)
        let bottomLeading = steps(cornerRadii.bottomLeading)

        // The path starts at the top center and runs clockwise, as
        // `Circle` does after a -90 degree turn, so a trimmed pixel
        // ring fills from 12 o'clock.
        var points = [CGPoint(x: r.midX, y: r.minY)]
        for (row, x) in topTrailing.enumerated() {
            points.append(CGPoint(x: r.maxX - x, y: r.minY + CGFloat(row) * s))
            points.append(CGPoint(x: r.maxX - x, y: r.minY + CGFloat(row + 1) * s))
        }
        points.append(CGPoint(x: r.maxX, y: r.minY + CGFloat(topTrailing.count) * s))
        points.append(CGPoint(x: r.maxX, y: r.maxY - CGFloat(bottomTrailing.count) * s))
        for (row, x) in bottomTrailing.enumerated().reversed() {
            points.append(CGPoint(x: r.maxX - x, y: r.maxY - CGFloat(row + 1) * s))
            points.append(CGPoint(x: r.maxX - x, y: r.maxY - CGFloat(row) * s))
        }
        for (row, x) in bottomLeading.enumerated() {
            points.append(CGPoint(x: r.minX + x, y: r.maxY - CGFloat(row) * s))
            points.append(CGPoint(x: r.minX + x, y: r.maxY - CGFloat(row + 1) * s))
        }
        points.append(CGPoint(x: r.minX, y: r.maxY - CGFloat(bottomLeading.count) * s))
        points.append(CGPoint(x: r.minX, y: r.minY + CGFloat(topLeading.count) * s))
        for (row, x) in topLeading.enumerated().reversed() {
            points.append(CGPoint(x: r.minX + x, y: r.minY + CGFloat(row + 1) * s))
            points.append(CGPoint(x: r.minX + x, y: r.minY + CGFloat(row) * s))
        }

        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

extension Shape where Self == PixelRect {
    static func pixelRect(cornerRadius: CGFloat) -> PixelRect { PixelRect(cornerRadius: cornerRadius) }
    static func pixelRect(cornerRadii: RectangleCornerRadii) -> PixelRect {
        PixelRect(cornerRadii: cornerRadii)
    }
    static var pixelCapsule: PixelRect { PixelRect(cornerRadius: .infinity) }
}
