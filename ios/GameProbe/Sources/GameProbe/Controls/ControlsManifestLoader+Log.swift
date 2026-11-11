// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

extension ControlsManifestLoader.Finding {
    public func logLine(prefix: String) -> String {
        "\(prefix) [\(code)] (\(severity == .error ? "error" : "warning")) \(path): \(message)"
    }
}

extension ControlsManifestLoader.LoadOutcome {
    private typealias Location = ControlsManifestLoader.ManifestLocation

    public var logLines: [String] {
        var lines = notes.map(Self.logLine(for:))
        if result.ignoredNewerVersion {
            lines.append("\(Self.prefix(.root)) Ignored manifest with version > 1")
        }
        let prefix = Self.prefix(result.location ?? .root)
        return lines + result.findings.map { $0.logLine(prefix: prefix) }
    }

    private static func prefix(_ location: Location) -> String {
        "\(location.rawValue.split(separator: "/").last ?? ""):"
    }

    private static func logLine(for note: Note) -> String {
        let root = "\(prefix(.root)) Ignored \(Location.root.rawValue) at game root"
        return switch note {
        case .rootSkippedBecauseEmpoExists:
            "\(prefix(.root)) Skipped \(Location.root.rawValue) at game root, using \(Location.empo.rawValue)"
        case .rootUnclaimedNoVersion:
            "\(root) (no version key, so not an Empo manifest)"
        case .rootUnclaimedNotObject:
            "\(root) (not a JSON object, so not an Empo manifest)"
        case .rootUnclaimedOversized:
            "\(root) (larger than \(ControlLimits.maxFileSizeText), so not an Empo manifest)"
        case .kirinSkippedBecauseManifestExists:
            "\(prefix(.kirin)) Skipped (an Empo controls manifest takes precedence)"
        case .joiplaySkippedBecauseOtherSourceExists:
            "\(prefix(.joiplay)) Skipped (a controls manifest or Kirin layout takes precedence)"
        }
    }
}
