import Foundation

/// A game-picture region as fractions of the window, top-left
/// origin. Dimensionless, so it survives rotation and device
/// changes.
public struct ScreenRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// Rounded to 4 decimals, the serializer's precision, so a
    /// round-trip compares equal.
    public func rounded() -> ScreenRegion {
        func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        return ScreenRegion(x: round4(x), y: round4(y), w: round4(w), h: round4(h))
    }
}

/// `Profiles/<Name>/screen.json`: Empo-private, profiles only. NOT
/// part of the frozen controls v1 spec; the loader never reads it
/// from game folders. Strict parse with its own small `S` finding
/// namespace. Invalid content counts as absent for resolution.
public enum ScreenRegionFile {
    public static let fileName = "screen.json"

    /// Regions below this width or height fraction are invalid.
    public static let minFraction = 0.25

    /// Tolerance at the `x + w <= 1` boundary, so authored values
    /// like 0.3 + 0.7 survive floating-point noise.
    public static let boundsEpsilon = 1e-6

    public struct ReadResult: Equatable, Sendable {
        public var portrait: ScreenRegion?
        public var landscape: ScreenRegion?
        public var findings: [String]

        public init(
            portrait: ScreenRegion? = nil, landscape: ScreenRegion? = nil,
            findings: [String] = []
        ) {
            self.portrait = portrait
            self.landscape = landscape
            self.findings = findings
        }
    }

    // MARK: - Parse

    public static func parse(_ data: Data) -> ReadResult {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else {
            return ReadResult(findings: ["S001: screen.json is not a JSON object"])
        }
        guard let version = object["version"] as? Int, version == 1 else {
            return ReadResult(findings: ["S002: version is missing or not 1"])
        }

        var findings: [String] = []
        for key in object.keys.sorted() where !["version", "portrait", "landscape"].contains(key) {
            findings.append("W-S1: unknown key '\(key)' (dropped on rewrite)")
        }

        let portrait = parseEntry(object["portrait"], key: "portrait", findings: &findings)
        let landscape = parseEntry(object["landscape"], key: "landscape", findings: &findings)
        return ReadResult(portrait: portrait, landscape: landscape, findings: findings)
    }

    private static func parseEntry(
        _ raw: Any?, key: String, findings: inout [String]
    ) -> ScreenRegion? {
        guard let raw else { return nil }
        guard let entry = raw as? [String: Any] else {
            findings.append("S003: '\(key)' is not an object")
            return nil
        }
        func number(_ field: String) -> Double? {
            (entry[field] as? NSNumber)?.doubleValue
        }
        guard let x = number("x"), let y = number("y"),
            let w = number("w"), let h = number("h")
        else {
            findings.append("S004: '\(key)' is missing x/y/w/h numbers")
            return nil
        }
        let region = ScreenRegion(x: x, y: y, w: w, h: h).rounded()
        guard region.x >= 0, region.y >= 0,
            region.w >= minFraction, region.h >= minFraction,
            region.x + region.w <= 1 + boundsEpsilon,
            region.y + region.h <= 1 + boundsEpsilon
        else {
            findings.append("S005: '\(key)' region is out of bounds or below the minimum size")
            return nil
        }
        return region
    }

    // MARK: - Serialize

    /// Stable bytes: fixed key order, fixed 4-decimal numbers. Only
    /// the orientations that exist are written. Both nil returns nil
    /// — the caller deletes the file instead of writing an empty one.
    public static func serialize(portrait: ScreenRegion?, landscape: ScreenRegion?) -> Data? {
        guard portrait != nil || landscape != nil else { return nil }
        func entry(_ key: String, _ region: ScreenRegion) -> String {
            let r = region.rounded()
            return "  \"\(key)\": { \"x\": \(format(r.x)), \"y\": \(format(r.y)), "
                + "\"w\": \(format(r.w)), \"h\": \(format(r.h)) }"
        }
        var entries = ["  \"version\": 1"]
        if let portrait { entries.append(entry("portrait", portrait)) }
        if let landscape { entries.append(entry("landscape", landscape)) }
        return Data(("{\n" + entries.joined(separator: ",\n") + "\n}\n").utf8)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
