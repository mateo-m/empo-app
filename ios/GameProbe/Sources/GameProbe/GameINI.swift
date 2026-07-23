import Foundation

public enum GameINI {
    public static func parseINIValue(at gameDir: URL, section: String, key: String) -> String? {
        let fm = FileManager.default
        let iniURL: URL? = {
            let gameIni = gameDir.appendingPathComponent("Game.ini")
            if fm.fileExists(atPath: gameIni.path) { return gameIni }
            if let items = try? fm.contentsOfDirectory(atPath: gameDir.path) {
                for item in items where item.lowercased().hasSuffix(".ini") {
                    return gameDir.appendingPathComponent(item)
                }
            }
            return nil
        }()
        guard let iniURL else { return nil }
        return parseINIValue(in: iniURL, section: section, key: key)
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
