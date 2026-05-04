import UIKit

/// Pixelated 16x16 SVG icon pack used by the splash background's
/// panning pattern. The icons are from the Smallbits pack by
/// Minor Adventures (https://smallbits.design - free for
/// commercial use under the Smallbits License). They live in
/// `Assets.bundle/SplashIcons/` (see project.yml's "Assemble
/// Assets.bundle" step) and are rasterized on demand via a tiny
/// in-process SVG parser that handles the `M` / `H` / `V` / `Z`
/// subset of path syntax used by every icon in the pack. We
/// deliberately avoid pulling in a third-party SVG library or
/// pre-rasterizing at build time:
///   - The pack is 202 simple shapes with single-color fills.
///   - The parser surface is ~30 lines, runs once per icon at
///     splash time, and produces a `UIBezierPath` we can fill at
///     any point size.
///   - Pre-rasterizing to PNG would force a build dependency on a
///     converter (rsvg-convert / ImageMagick / Inkscape) that
///     wasn't already in our toolchain.
///
/// Usage:
///   `SplashIcons.randomIconNames(count: 6)` -> shuffled subset.
///   `SplashIcons.path(for: name)`           -> filled UIBezierPath.
enum SplashIcons {

    /// Curated subset of the icon pack used by the splash background.
    ///
    /// We deliberately ship only geometric-primitive shapes here -
    /// circles, squares, diamond, heart, star, plus, cube, sphere -
    /// since the splash backdrop reads better as an abstract pattern
    /// than as a wall of literal UI affordances (arrows, gears,
    /// document outlines, etc. would compete for attention with the
    /// "Empo" wordmark and look like accidental UI). The full pack
    /// is still on disk under `Assets.bundle/SplashIcons/`; if a
    /// future surface (settings background, empty state, etc.)
    /// wants the broader set, expose another curated list here
    /// rather than dropping the filter.
    static let allNames: [String] = [
        "circle", "circle-filled",
        "square", "square-filled",
        "square-rounded", "square-rounded-filled",
        "diamond",
        "heart",
        "star",
        "plus",
        "cube",
        "sphere",
    ]

    /// Pick `count` random icon basenames without replacement. If
    /// the pack has fewer icons than requested, returns whatever's
    /// available (caller is responsible for handling shortfalls).
    static func randomNames(count: Int) -> [String] {
        Array(allNames.shuffled().prefix(count))
    }

    /// Resolve `name` to a `UIBezierPath` filled-region representation.
    /// Returns nil if the SVG is missing or its path data fails to
    /// parse. Output coordinates are in the SVG's native viewBox
    /// space (`0...16`); callers translate / scale via
    /// `CGAffineTransform` to draw at the desired pixel size.
    static func path(for name: String) -> UIBezierPath? {
        guard
            let bundleURL = Bundle.main.url(
                forResource: "Assets", withExtension: "bundle"
            )
        else { return nil }
        let svgURL =
            bundleURL
            .appendingPathComponent("SplashIcons")
            .appendingPathComponent("\(name).svg")
        guard let text = try? String(contentsOf: svgURL, encoding: .utf8)
        else { return nil }
        guard let pathData = extractPathData(from: text) else { return nil }
        return parsePathData(pathData)
    }

    // MARK: - Internal: SVG extraction

    /// Pull the first `<path d="...">` value out of `svg`. The icon
    /// pack stores everything in a single path per file; if a
    /// future icon variant uses multiple paths or other shapes
    /// (`<rect>`, `<circle>`, etc.) this loader silently drops
    /// them - acceptable since the curated pack is single-path.
    private static func extractPathData(from svg: String) -> String? {
        guard let dRange = svg.range(of: "d=\"") else { return nil }
        let afterQuote = dRange.upperBound
        guard let endQuote = svg.range(of: "\"", range: afterQuote..<svg.endIndex)
        else { return nil }
        return String(svg[afterQuote..<endQuote.lowerBound])
    }

    /// Parse a pixel-art SVG path comprising only `M x y`, `H x`,
    /// `V y`, and `Z` commands at integer coordinates. Returns a
    /// non-zero-fill UIBezierPath ready to drop into a graphics
    /// context with any uniform color set as the fill style.
    ///
    /// The SVG spec treats each `M` after the first as starting
    /// an implicit subpath, which we honor by leaving the prior
    /// `Z` (or implicit close) untouched and starting a fresh
    /// `move(to:)`. Holes inside icons (e.g. the inner notch of
    /// `archive.svg`'s lid) come out correctly under non-zero
    /// winding because each subpath traces the perimeter in a
    /// consistent direction.
    private static func parsePathData(_ d: String) -> UIBezierPath {
        let path = UIBezierPath()
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var i = d.startIndex
        let end = d.endIndex

        while i < end {
            let ch = d[i]
            if ch.isWhitespace || ch == "," {
                i = d.index(after: i)
                continue
            }
            switch ch {
            case "M":
                i = d.index(after: i)
                let (nx, j1) = readNumber(d, from: i)
                let (ny, j2) = readNumber(d, from: skipSeps(d, from: j1))
                currentX = nx
                currentY = ny
                path.move(to: CGPoint(x: currentX, y: currentY))
                i = j2
            case "H":
                i = d.index(after: i)
                let (nx, j) = readNumber(d, from: i)
                currentX = nx
                path.addLine(to: CGPoint(x: currentX, y: currentY))
                i = j
            case "V":
                i = d.index(after: i)
                let (ny, j) = readNumber(d, from: i)
                currentY = ny
                path.addLine(to: CGPoint(x: currentX, y: currentY))
                i = j
            case "Z", "z":
                path.close()
                i = d.index(after: i)
            default:
                // Unsupported command (curve, arc, lowercase
                // relative form, etc.). Skip a single byte; the
                // outer whitespace loop will resync on the next
                // recognized command. No icon in the curated pack
                // hits this branch today.
                i = d.index(after: i)
            }
        }
        return path
    }

    private static func readNumber(
        _ s: String, from idx: String.Index
    )
        -> (CGFloat, String.Index)
    {
        var i = skipSeps(s, from: idx)
        let end = s.endIndex
        let start = i
        if i < end && s[i] == "-" { i = s.index(after: i) }
        while i < end {
            let c = s[i]
            if c.isNumber || c == "." {
                i = s.index(after: i)
            } else {
                break
            }
        }
        let num = CGFloat(Double(s[start..<i]) ?? 0)
        return (num, i)
    }

    private static func skipSeps(
        _ s: String, from idx: String.Index
    )
        -> String.Index
    {
        var i = idx
        let end = s.endIndex
        while i < end && (s[i].isWhitespace || s[i] == ",") {
            i = s.index(after: i)
        }
        return i
    }
}
