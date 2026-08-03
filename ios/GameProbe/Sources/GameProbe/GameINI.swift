import Foundation

public enum GameINI {
    /// Reads `[section] key=value`, looking in `Game.ini` first and
    /// then in every other `*.ini` in the directory, in sorted
    /// order, until one yields a value. Two properties matter here
    /// because folder identity and the shared data directory both
    /// derive from the INI title:
    ///
    ///   - Deterministic: `contentsOfDirectory` order is
    ///     unspecified and can change when the file set changes, so
    ///     the candidates are sorted before the scan. Without this,
    ///     a game with two inis could resolve a different title
    ///     across imports.
    ///   - Value-seeking: an ini without the requested value
    ///     (a settings or installer ini) does not end the scan.
    public static func parseINIValue(at gameDir: URL, section: String, key: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: gameDir.path) else {
            return nil
        }
        // The primary ini comes from the directory LISTING, never
        // from a `fileExists("Game.ini")` probe: that probe is
        // case-insensitive on Darwin and case-sensitive on
        // iOS/Linux, so a lowercase `game.ini` would change
        // priority between the platforms. The listing-based pick
        // behaves identically everywhere.
        let candidates =
            items
            .filter { $0.lowercased().hasSuffix(".ini") }
            .sorted()
        let primary = candidates.first { $0.lowercased() == "game.ini" }
        if let primary,
            let value = parseINIValue(
                in: gameDir.appendingPathComponent(primary), section: section, key: key)
        {
            return value
        }
        for item in candidates where item != primary {
            if let value = parseINIValue(
                in: gameDir.appendingPathComponent(item), section: section, key: key)
            {
                return value
            }
        }
        return nil
    }

    /// Reads `[section] key=value` from a Game.ini file. The parser
    /// matches `section` and `key` without case. It accepts optional
    /// whitespace around `=` (`title =BLACK SOULS`).
    public static func parseINIValue(in iniURL: URL, section: String, key: String) -> String? {
        guard let value = try? Data(contentsOf: iniURL).decodeAsLooseText() else {
            return nil
        }

        let sectionLower = "[\(section.lowercased())]"
        let keyLower = key.lowercased()
        var inSection = false
        for line in value.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.lowercased().hasPrefix(sectionLower)
                continue
            }
            if inSection {
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let lineKey = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                guard lineKey == keyLower else { continue }
                let v = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }
}
