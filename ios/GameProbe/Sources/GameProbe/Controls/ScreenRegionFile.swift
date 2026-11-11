// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Fractions of the window, with a top-left origin. `overlay` puts the
/// touch controls over the game, not in a zone below it.
public struct ScreenRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var overlay: Bool

    public init(x: Double, y: Double, w: Double, h: Double, overlay: Bool = false) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.overlay = overlay
    }

    /// Rounded to 4 decimals, the serializer's precision, so a
    /// round-trip compares equal.
    public func rounded() -> ScreenRegion {
        func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        return ScreenRegion(
            x: round4(x), y: round4(y), w: round4(w), h: round4(h), overlay: overlay)
    }
}

public enum ScreenPreset: String, CaseIterable, Sendable {
    case top
    case topCenter = "top-center"
    case center
}

public enum ScreenPlacement: Equatable, Sendable {
    case preset(ScreenPreset)
    case region(ScreenRegion)

    public var region: ScreenRegion? {
        if case .region(let region) = self { return region }
        return nil
    }

    public var overlay: Bool {
        region?.overlay ?? false
    }
}

/// This file is only in profile folders. It is not part of the frozen
/// controls v1 spec, and the loader never reads it from game folders.
public enum ScreenRegionFile {
    public static let fileName = "screen.json"

    public static let minFraction = 0.25

    /// Tolerance at the `x + w <= 1` boundary, so authored values
    /// like 0.3 + 0.7 survive floating-point noise.
    public static let boundsEpsilon = 1e-6

    public struct ReadResult: Equatable, Sendable {
        public var portrait: ScreenPlacement?
        public var landscape: ScreenPlacement?
        public var findings: [String]

        public init(
            portrait: ScreenPlacement? = nil, landscape: ScreenPlacement? = nil,
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
        guard let rawVersion = object["version"], let version = JSONNumber.int(rawVersion),
            version == 1
        else {
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
    ) -> ScreenPlacement? {
        guard let raw else { return nil }
        if let text = raw as? String {
            guard let preset = ScreenPreset(rawValue: text) else {
                findings.append("S006: '\(key)' names an unknown preset: \(text)")
                return nil
            }
            return .preset(preset)
        }
        guard let entry = raw as? [String: Any] else {
            findings.append("S003: '\(key)' is not an object or a preset name")
            return nil
        }
        func number(_ field: String) -> Double? {
            JSONNumber.double(entry[field])
        }
        guard let x = number("x"), let y = number("y"),
            let w = number("w"), let h = number("h")
        else {
            findings.append("S004: '\(key)' is missing x/y/w/h numbers")
            return nil
        }
        let overlay = JSONNumber.bool(entry["overlay"]) ?? false
        let region = ScreenRegion(x: x, y: y, w: w, h: h, overlay: overlay).rounded()
        guard region.x >= 0, region.y >= 0,
            region.w >= minFraction, region.h >= minFraction,
            region.x + region.w <= 1 + boundsEpsilon,
            region.y + region.h <= 1 + boundsEpsilon
        else {
            findings.append("S005: '\(key)' region is out of bounds or below the minimum size")
            return nil
        }
        return .region(region)
    }

    // MARK: - Serialize

    /// Stable bytes: fixed key order, fixed 4-decimal numbers.
    public static func serialize(
        portrait: ScreenPlacement?, landscape: ScreenPlacement?
    ) -> Data? {
        guard portrait != nil || landscape != nil else { return nil }
        func entry(_ key: String, _ placement: ScreenPlacement) -> String {
            switch placement {
            case .preset(let preset):
                return "  \"\(key)\": \"\(preset.rawValue)\""
            case .region(let region):
                let r = region.rounded()
                let overlay = r.overlay ? ", \"overlay\": true" : ""
                return "  \"\(key)\": { \"x\": \(format(r.x)), \"y\": \(format(r.y)), "
                    + "\"w\": \(format(r.w)), \"h\": \(format(r.h))\(overlay) }"
            }
        }
        var entries = ["  \"version\": 1"]
        if let portrait { entries.append(entry("portrait", portrait)) }
        if let landscape { entries.append(entry("landscape", landscape)) }
        return Data(("{\n" + entries.joined(separator: ",\n") + "\n}\n").utf8)
    }

    // The explicit POSIX locale keeps the decimal separator a "."
    // on every device locale, so the output stays valid JSON.
    private static func format(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
