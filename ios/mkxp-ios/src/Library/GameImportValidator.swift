import Foundation

enum GameImportValidator {

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unzipFailed
        case corruptZip(String)
        case notAnRPGMakerGame
        case unsupportedRuntime(String)
        case missingScripts(String)
        case invalidScripts(String)

        var errorDescription: String? {
            switch self {
            case .unzipFailed:
                return "Failed to extract the zip file."
            case .corruptZip(let detail):
                return "Corrupt zip file: \(detail)"
            case .notAnRPGMakerGame:
                return "This doesn't appear to be an RPG Maker game. No valid Game.ini or RGSS archive was found."
            case .unsupportedRuntime(let detail):
                return detail
            case .missingScripts(let path):
                return "Script file not found: \(path)"
            case .invalidScripts(let path):
                return "Script file is not a valid RGSS data file: \(path)"
            }
        }
    }

    // MARK: - Public

    /// Validates that a directory is a valid RPG Maker game we can run.
    /// Throws ImportError on failure.
    static func validate(_ url: URL) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else {
            throw ImportError.notAnRPGMakerGame
        }

        let lowercaseItems = items.map { $0.lowercased() }

        // 1. Check for RGSS archive — definitive proof + version detection.
        //    When an archive is present, scripts are packed inside it and
        //    we can't validate them without decrypting, so just check version.
        if let version = rgssVersionFromArchive(lowercaseItems) {
            try checkRuntimeSupport(version)
            return
        }

        // 2. Check .ini files for [Game] section with Scripts= entry
        for item in items where item.lowercased().hasSuffix(".ini") {
            let iniURL = url.appendingPathComponent(item)
            if let (version, scriptsPath) = parseIniScripts(iniURL) {
                try checkRuntimeSupport(version)
                try validateRGSSScripts(at: url, scriptsPath: scriptsPath)
                return
            }
        }

        // 3. Check for mkxp.json — only valid if it has a customScript
        //    (without customScript AND without a valid .ini, the engine
        //    won't know where to find scripts and will fail at runtime)
        if lowercaseItems.contains("mkxp.json") {
            if let scriptPath = customScriptPath(url) {
                try validateCustomScript(at: url, scriptPath: scriptPath)
                if let version = rgssVersionFromMkxpJson(url) {
                    try checkRuntimeSupport(version)
                }
                return
            }
        }

        // Nothing matched — not an RPG Maker game
        throw ImportError.notAnRPGMakerGame
    }

    // MARK: - RGSS Version Detection

    /// Detected RGSS version: 1 = XP, 2 = VX, 3 = VX Ace
    private enum RGSSVersion: Int {
        case xp = 1, vx = 2, vxAce = 3
    }

    private static func rgssVersionFromArchive(_ lowercaseItems: [String]) -> RGSSVersion? {
        if lowercaseItems.contains(where: { $0.hasSuffix(".rgssad") }) { return .xp }
        if lowercaseItems.contains(where: { $0.hasSuffix(".rgss2a") }) { return .vx }
        if lowercaseItems.contains(where: { $0.hasSuffix(".rgss3a") }) { return .vxAce }
        return nil
    }

    private static func rgssVersionFromMkxpJson(_ url: URL) -> RGSSVersion? {
        let jsonURL = url.appendingPathComponent("mkxp.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ver = json["rgssVersion"] as? Int else {
            return nil
        }
        return RGSSVersion(rawValue: ver)
    }

    // MARK: - INI Scripts Detection

    /// Parses an .ini file looking for a [Game] section with a Scripts= entry.
    /// Returns the detected RGSS version and the raw scripts path.
    private static func parseIniScripts(_ iniURL: URL) -> (RGSSVersion, String)? {
        guard let content = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return nil
        }

        var inGameSection = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inGameSection = trimmed.lowercased().hasPrefix("[game]")
                continue
            }
            if inGameSection && trimmed.lowercased().hasPrefix("scripts=") {
                let value = String(trimmed.dropFirst("scripts=".count))
                    .trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }
                let lower = value.lowercased()
                let version: RGSSVersion
                if lower.hasSuffix(".rvdata2") { version = .vxAce }
                else if lower.hasSuffix(".rvdata") { version = .vx }
                else { version = .xp }
                return (version, value)
            }
        }
        return nil
    }

    // MARK: - Script File Validation

    /// Validates that an RGSS scripts file (Marshal-dumped Array) exists and is valid.
    private static func validateRGSSScripts(at gameDir: URL, scriptsPath: String) throws {
        // Game.ini uses backslashes (Windows paths) — convert to forward slashes
        let normalized = scriptsPath.replacingOccurrences(of: "\\", with: "/")
        let fileURL = gameDir.appendingPathComponent(normalized)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.missingScripts(normalized)
        }

        // Ruby Marshal format: first 2 bytes are version (0x04, 0x08),
        // third byte is the type tag — 0x5B means Array
        guard let fh = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ImportError.invalidScripts(normalized)
        }
        defer { fh.closeFile() }

        let header = fh.readData(ofLength: 3)
        guard header.count == 3,
              header[0] == 0x04,
              header[1] == 0x08,
              header[2] == 0x5B else {
            throw ImportError.invalidScripts(normalized)
        }
    }

    /// Validates that a customScript .rb file exists.
    private static func validateCustomScript(at gameDir: URL, scriptPath: String) throws {
        let normalized = scriptPath.replacingOccurrences(of: "\\", with: "/")
        let fileURL = gameDir.appendingPathComponent(normalized)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.missingScripts(normalized)
        }
    }

    // MARK: - mkxp.json

    private static func customScriptPath(_ url: URL) -> String? {
        let jsonURL = url.appendingPathComponent("mkxp.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = json["customScript"] as? String,
              !script.isEmpty else {
            return nil
        }
        return script
    }

    // MARK: - Runtime Support

    private static func checkRuntimeSupport(_ version: RGSSVersion) throws {
        // Currently we ship Ruby 1.8, which supports RGSS1 (XP) and RGSS2 (VX).
        // RGSS3 (VX Ace) requires Ruby 1.9+ which we don't have yet.
        if version == .vxAce {
            throw ImportError.unsupportedRuntime(
                "This game requires RPG Maker VX Ace (RGSS3) which isn't supported yet. "
                + "Only RPG Maker XP and VX games are currently supported."
            )
        }
    }
}
