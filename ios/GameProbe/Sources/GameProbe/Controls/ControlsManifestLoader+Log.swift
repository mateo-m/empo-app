// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

extension ControlsManifestLoader.Finding {
    /// Such as "controls.json: [W001] (warning) /touch: Unknown key".
    public func logLine(prefix: String) -> String {
        "\(prefix) [\(code)] (\(severity == .error ? "error" : "warning")) \(path): \(message)"
    }
}

extension ControlsManifestLoader.LoadOutcome {
    /// The lines for the game's `controls.json.log`.
    public var logLines: [String] {
        var lines = notes.map(Self.logLine(for:))
        if result.ignoredNewerVersion {
            lines.append("controls.json: Ignored manifest with version > 1")
        }
        let prefix =
            switch result.location {
            case .kirin: "kirin-touch-controls.json:"
            case .joiplay: "gamepad.json:"
            default: "controls.json:"
            }
        return lines + result.findings.map { $0.logLine(prefix: prefix) }
    }

    private static func logLine(for note: Note) -> String {
        switch note {
        case .rootSkippedBecauseEmpoExists:
            "controls.json: Skipped controls.json at game root, using empo/controls.json"
        case .rootUnclaimedNoVersion:
            "controls.json: Ignored controls.json at game root (no version key, so not an Empo manifest)"
        case .rootUnclaimedNotObject:
            "controls.json: Ignored controls.json at game root (not a JSON object, so not an Empo manifest)"
        case .rootUnclaimedOversized:
            "controls.json: Ignored controls.json at game root (larger than 128 KiB, so not an Empo manifest)"
        case .kirinSkippedBecauseManifestExists:
            "kirin-touch-controls.json: Skipped (an Empo controls manifest takes precedence)"
        case .joiplaySkippedBecauseOtherSourceExists:
            "gamepad.json: Skipped (a controls manifest or Kirin layout takes precedence)"
        }
    }
}
