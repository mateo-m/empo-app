import Foundation

enum GameImportValidator {


    enum ImportError: LocalizedError {
        case unzipFailed
        case corruptZip(String)
        case notAnRPGMakerGame
        case unsupportedRuntime(String)
        case missingScripts(String)
        case invalidScripts(String)
        // JoiPlay .jgp specific
        case invalidJgpManifest

        var errorDescription: String? {
            switch self {
            case .unzipFailed:
                return "Failed to extract the zip file."
            case .corruptZip(let detail):
                return "Corrupt zip file: \(detail)"
            case .notAnRPGMakerGame:
                return "This doesn't appear to be an RPG Maker game. No recognised game configuration was found."
            case .unsupportedRuntime(let detail):
                return detail
            case .missingScripts(let path):
                return "Script file not found: \(path)"
            case .invalidScripts(let path):
                return "Script file is not a valid RGSS data file: \(path)"
            case .invalidJgpManifest:
                return "The JoiPlay archive is missing or has an invalid manifest.json."
            }
        }
    }


    /// Throws ImportError on failure. Validates a folder already
    /// present on disk - used both for full extracted imports and
    /// folder-based imports. Archives peek first via
    /// `preflightArchive` to avoid paying the full extract cost
    /// before the user sees confirmation the game is valid.
    static func validate(_ url: URL) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else {
            throw ImportError.notAnRPGMakerGame
        }

        let lowercaseItems = items.map { $0.lowercased() }

        // 1. Check for RGSS archive; definitive proof + version detection.
        //    When an archive is present, scripts are packed inside it and
        //    scripts can't be validated without decrypting, so only the version is checked.
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

        // 3. Check for mkxp.json; only valid if it has a customScript
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

        throw ImportError.notAnRPGMakerGame
    }


    /// Pre-flight check for archive imports. Walks the archive
    /// once (a second pass only runs when the game uses a
    /// non-standard scripts path) and selectively extracts just
    /// the validation files (`.ini`, `mkxp.json`, and
    /// `Data/Scripts.*`) into `scratchDir` so the normal folder
    /// validator can inspect them. Returns the URL of the game
    /// root inside `scratchDir` (for the caller to read
    /// `parseINITitle` against). Throws with a user-facing
    /// `ImportError` if the archive isn't a supported RPG Maker
    /// game.
    ///
    /// The single-walk strategy assumes RPG Maker games keep the
    /// scripts file at the default `Data/Scripts.{rxdata,rvdata,
    /// rvdata2}` path (which covers nearly all of them). If a
    /// game hard-codes a custom scripts path via Game.ini's
    /// `Scripts=` key falls through to a targeted second pass.
    ///
    /// Artwork is not pulled by the pre-flight: archive order
    /// typically places `Data/Scripts.*` before `Graphics/Titles/*`,
    /// so a walk wide enough to catch both would no longer
    /// short-circuit on typical archives. The full-extract pass
    /// surfaces artwork mid-flight via its per-file callback
    /// instead.
    @discardableResult
    static func preflightArchive(
        at archiveURL: URL,
        scratchDir: URL,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: scratchDir.path) {
            try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        }

        // State tracked during the walk. The walk stops early
        // when any of these prove the game is valid:
        //   1. RGSS archive marker (`.rgssad`/`.rgss2a`/`.rgss3a`)
        //      at the game root - its name alone is sufficient.
        //   2. Both a root `.ini`/`mkxp.json` AND a
        //      `Data/Scripts.*` file. Between them the folder
        //      validator has everything it needs - no point
        //      walking the rest of a 700MB archive just to hit
        //      EOF.
        var rgssArchiveVersion: RGSSVersion?
        var sawMetadata = false
        var sawScripts = false

        do {
            try ArchiveExtractor.extractSelective(
                archive: archiveURL,
                to: scratchDir,
                shouldCancel: shouldCancel,
                stopWhen: {
                    rgssArchiveVersion != nil || (sawMetadata && sawScripts)
                }
            ) { path in
                let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                // `depth` counts how many folder hops away from the
                // archive root the entry sits. Files are accepted at
                // depth 0 (flat archive) and depth 1 (wrapper
                // folder) for metadata; scripts files live one
                // deeper because they're inside Data/.
                let depth = components.count - 1
                guard let name = components.last?.lowercased() else { return false }

                // Game root metadata files.
                if depth <= 1 {
                    if name.hasSuffix(".ini") || name == "mkxp.json" {
                        sawMetadata = true
                        return true
                    }
                    if name.hasSuffix(".rgssad") {
                        rgssArchiveVersion = .xp
                        return false
                    }
                    if name.hasSuffix(".rgss2a") {
                        rgssArchiveVersion = .vx
                        return false
                    }
                    if name.hasSuffix(".rgss3a") {
                        rgssArchiveVersion = .vxAce
                        return false
                    }
                }

                // Speculative scripts extraction: catches the
                // default `Data/Scripts.*` layout. Games with a
                // custom Scripts= path fall through to the second
                // pass below.
                if depth == 1 || depth == 2 {
                    let parent = components.count >= 2 ? components[components.count - 2].lowercased() : ""
                    if parent == "data",
                       name.hasPrefix("scripts."),
                       name.hasSuffix(".rxdata") || name.hasSuffix(".rvdata") || name.hasSuffix(".rvdata2") {
                        sawScripts = true
                        return true
                    }
                }

                // Artwork is deliberately NOT extracted here.
                // Archives tend to be alphabetical, putting
                // `Data/Scripts.*` before `Graphics/Titles/*`, so
                // the walk's `stopWhen` predicate would fire before
                // any artwork is reached. The full-extract pass
                // later surfaces artwork via its per-file callback.

                return false
            }
        } catch ArchiveExtractor.Error.cancelled {
            throw ArchiveExtractor.Error.cancelled
        } catch {
            throw ImportError.corruptZip(error.localizedDescription)
        }

        // Determine where the game root landed inside scratchDir
        // based on what got extracted (matches the
        // post-extraction logic that the full import uses later).
        let gameRoot = GameContainer.findGameRoot(in: scratchDir, fm: fm)

        // Fast path: RGSS-archived games were identified by name
        // during the walk.
        if let version = rgssArchiveVersion {
            try checkRuntimeSupport(version)
            return gameRoot
        }

        var scriptsPath: String?
        var detectedVersion: RGSSVersion?
        if let items = try? fm.contentsOfDirectory(atPath: gameRoot.path) {
            for item in items where item.lowercased().hasSuffix(".ini") {
                let iniURL = gameRoot.appendingPathComponent(item)
                if let (version, path) = parseIniScripts(iniURL) {
                    detectedVersion = version
                    scriptsPath = path
                    break
                }
            }
        }

        // Fall back to mkxp.json's customScript when no ini
        // yielded a scripts path.
        var customScriptPath: String?
        let mkxpURL = gameRoot.appendingPathComponent("mkxp.json")
        if scriptsPath == nil, fm.fileExists(atPath: mkxpURL.path) {
            customScriptPath = Self.customScriptPath(gameRoot)
            if customScriptPath == nil {
                throw ImportError.notAnRPGMakerGame
            }
            detectedVersion = rgssVersionFromMkxpJson(gameRoot)
        }

        guard scriptsPath != nil || customScriptPath != nil else {
            throw ImportError.notAnRPGMakerGame
        }

        if let detectedVersion {
            try checkRuntimeSupport(detectedVersion)
        }

        // Validate the scripts/customScript file. Usually already
        // on disk from the single walk; second pass only runs when
        // the game uses a non-standard path.
        if let scriptsPath {
            let normalized = scriptsPath.replacingOccurrences(of: "\\", with: "/")
            try ensureFileExtracted(
                relativePath: normalized,
                gameRoot: gameRoot,
                archiveURL: archiveURL,
                scratchDir: scratchDir,
                shouldCancel: shouldCancel
            )
            try validateRGSSScripts(at: gameRoot, scriptsPath: normalized)
        } else if let customScriptPath {
            let normalized = customScriptPath.replacingOccurrences(of: "\\", with: "/")
            try ensureFileExtracted(
                relativePath: normalized,
                gameRoot: gameRoot,
                archiveURL: archiveURL,
                scratchDir: scratchDir,
                shouldCancel: shouldCancel
            )
            try validateCustomScript(at: gameRoot, scriptPath: normalized)
        }

        return gameRoot
    }


    /// Ensures `gameRoot/relativePath` exists on disk, running a
    /// targeted second archive walk only when the speculative
    /// first walk didn't pull the file. Handles both flat and
    /// single-wrapper archives by stripping the wrapper from
    /// archive paths before matching.
    private static func ensureFileExtracted(
        relativePath: String,
        gameRoot: URL,
        archiveURL: URL,
        scratchDir: URL,
        shouldCancel: (() -> Bool)?
    ) throws {
        let fm = FileManager.default
        let expected = gameRoot.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: expected.path) { return }

        let wrapperPrefix: String? = gameRoot == scratchDir
            ? nil
            : gameRoot.lastPathComponent + "/"

        var extracted = false
        try ArchiveExtractor.extractSelective(
            archive: archiveURL,
            to: scratchDir,
            shouldCancel: shouldCancel,
            stopWhen: { extracted }
        ) { rawPath in
            let archivePath = rawPath.replacingOccurrences(of: "\\", with: "/")
            let gameRelative: String
            if let prefix = wrapperPrefix {
                guard archivePath.hasPrefix(prefix) else { return false }
                gameRelative = String(archivePath.dropFirst(prefix.count))
            } else {
                gameRelative = archivePath
            }
            let match = gameRelative.caseInsensitiveCompare(relativePath) == .orderedSame
            if match { extracted = true }
            return match
        }
    }


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


    /// Returns the detected RGSS version and the raw scripts path.
    private static func parseIniScripts(_ iniURL: URL) -> (RGSSVersion, String)? {
        guard let value = GameEntry.parseINIValue(in: iniURL, section: "game", key: "scripts") else {
            return nil
        }
        let lower = value.lowercased()
        let version: RGSSVersion
        if lower.hasSuffix(".rvdata2") { version = .vxAce }
        else if lower.hasSuffix(".rvdata") { version = .vx }
        else { version = .xp }
        return (version, value)
    }


    /// Validates that an RGSS scripts file (Marshal-dumped Array) exists and is valid.
    private static func validateRGSSScripts(at gameDir: URL, scriptsPath: String) throws {
        // Game.ini uses backslashes (Windows paths); convert to forward slashes
        let normalized = scriptsPath.replacingOccurrences(of: "\\", with: "/")
        let fileURL = gameDir.appendingPathComponent(normalized)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.missingScripts(normalized)
        }

        // Ruby Marshal format: first 2 bytes are version (0x04, 0x08),
        // third byte is the type tag; 0x5B means Array
        guard let fh = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ImportError.invalidScripts(normalized)
        }
        defer { try? fh.close() }

        guard let header = try? fh.read(upToCount: 3) else {
            throw ImportError.invalidScripts(normalized)
        }
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


    private static func checkRuntimeSupport(_ version: RGSSVersion) throws {
        // Ask the engine which RGSS versions this build supports. The mask
        // depends on which Ruby runtime is linked (legacy Ruby 1.8 only runs
        // RGSS1 + RGSS2; Ruby 3.x with syntax transform runs all three).
        let mask = Int(mkxp_getSupportedRGSSVersionMask())
        let bit = 1 << (version.rawValue - 1)
        if mask & bit != 0 { return }

        let label: String
        switch version {
        case .xp:    label = "RPG Maker XP (RGSS1)"
        case .vx:    label = "RPG Maker VX (RGSS2)"
        case .vxAce: label = "RPG Maker VX Ace (RGSS3)"
        }
        throw ImportError.unsupportedRuntime(
            "This game requires \(label), which isn't supported right now."
        )
    }
}
