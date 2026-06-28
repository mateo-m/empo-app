import Foundation
import GameProbe

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
                return
                    "This doesn't appear to be an RPG Maker game. No recognised game configuration was found."
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

    struct ImportRootChoice: Identifiable, Hashable {
        let relativePath: String
        let title: String
        let subtitle: String
        let artwork: ImportRootChoiceArtwork?

        var id: String { relativePath }
    }

    private static let previewImageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]

    private struct ArchiveEntryDescriptor {
        let lowercaseName: String
        let parentComponents: [String]
        let parentPath: String

        init?(_ rawPath: String) {

            let components =
                rawPath
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)

            guard let name = components.last, !name.isEmpty else { return nil }

            lowercaseName = name.lowercased()
            parentComponents = Array(components.dropLast())
            parentPath = parentComponents.joined(separator: "/")
        }

        var isIni: Bool {
            lowercaseName.hasSuffix(".ini")
        }

        var isMkxpJson: Bool {
            lowercaseName == "mkxp.json"
        }

        var archiveMarkerVersion: RGSSVersion? {
            GameImportValidator.rgssVersion(fromArchiveMarker: lowercaseName)
        }

        var defaultScriptsRoot: String? {
            guard parentComponents.last?.lowercased() == "data" else { return nil }
            guard lowercaseName.hasPrefix("scripts.") else { return nil }
            guard
                lowercaseName.hasSuffix(".rxdata") || lowercaseName.hasSuffix(".rvdata")
                    || lowercaseName.hasSuffix(".rvdata2")
            else { return nil }

            return Array(parentComponents.dropLast()).joined(separator: "/")
        }

        var isExecutable: Bool {
            lowercaseName.hasSuffix(".exe")
        }

        var isPreviewTitleArtwork: Bool {
            guard parentComponents.count >= 2 else { return false }
            guard parentComponents[parentComponents.count - 2].lowercased() == "graphics" else {
                return false
            }
            guard parentComponents[parentComponents.count - 1].lowercased() == "titles" else {
                return false
            }

            let ext = (lowercaseName as NSString).pathExtension
            return GameImportValidator.previewImageExtensions.contains(ext)
        }
    }

    /// Throws ImportError on failure. Validates a folder already
    /// present on disk - used both for full extracted imports and
    /// folder-based imports. Archives peek first via
    /// `preflightArchive` to avoid paying the full extract cost
    /// before the user sees confirmation the game is valid.
    static func validate(_ url: URL) throws {
        guard let gameRoot = locateGameRoot(in: url) else {
            throw ImportError.notAnRPGMakerGame
        }
        try validateResolvedGameRoot(at: gameRoot)
    }

    static func importRootChoices(for sourceURL: URL) throws -> [ImportRootChoice] {
        if ArchiveExtractor.Format(extension: sourceURL.pathExtension) != nil {
            return try importRootChoices(inArchive: sourceURL)
        }
        return try importRootChoices(
            inDirectory: sourceURL,
            fallbackRootName: sourceURL.lastPathComponent,
            archiveURL: nil,
            scratchDir: nil
        )
    }

    /// Finds the actual game directory inside `url`, walking down
    /// through wrapper folders until it finds a directory that
    /// looks like an RPG Maker root. Returns the shallowest valid
    /// candidate so archives containing docs/readmes next to the
    /// game still resolve to the game folder.
    static func locateGameRoot(
        in url: URL,
        fm: FileManager = .default
    ) -> URL? {
        discoverLikelyGameRoots(in: url, fm: fm).first
    }

    static func resolveGameRoot(in baseURL: URL, relativePath: String) throws -> URL {
        let normalized = normalizedRelativePath(relativePath)
        let candidate =
            normalized.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(normalized, isDirectory: true)

        let basePath = baseURL.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == basePath || candidatePath.hasPrefix(basePath + "/") else {
            throw ImportError.notAnRPGMakerGame
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw ImportError.notAnRPGMakerGame
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ImportError.notAnRPGMakerGame
        }
        return candidate
    }

    private static func discoverLikelyGameRoots(
        in url: URL,
        fm: FileManager = .default
    ) -> [URL] {
        var queue = [url]
        var visited = Set<String>()
        var candidates: [URL] = []

        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            let key = candidate.standardizedFileURL.path
            if !visited.insert(key).inserted { continue }

            if isLikelyGameRoot(candidate, fm: fm) {
                candidates.append(candidate)
            }

            guard
                let items = try? fm.contentsOfDirectory(
                    at: candidate,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            let childDirectories = items.filter {
                $0.lastPathComponent != "__MACOSX"
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            queue.append(contentsOf: childDirectories.sorted { $0.path < $1.path })
        }

        return candidates
    }

    private static func validateResolvedGameRoot(
        at url: URL,
        archiveURL: URL? = nil,
        scratchDir: URL? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws {
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

        var scriptsPath: String?
        var detectedVersion: RGSSVersion?

        // 2. Check .ini files for [Game] section with Scripts= entry
        for item in items where item.lowercased().hasSuffix(".ini") {
            let iniURL = url.appendingPathComponent(item)
            if let (version, iniScriptsPath) = parseIniScripts(iniURL) {
                detectedVersion = version
                scriptsPath = iniScriptsPath
                break
            }
        }

        // 3. Check for mkxp.json; only valid if it has a customScript
        //    (without customScript AND without a valid .ini, the engine
        //    won't know where to find scripts and will fail at runtime)
        var customScriptPath: String?
        if lowercaseItems.contains("mkxp.json") {
            customScriptPath = Self.customScriptPath(url)
            if scriptsPath == nil, customScriptPath == nil {
                throw ImportError.notAnRPGMakerGame
            }
            if scriptsPath == nil {
                detectedVersion = rgssVersionFromMkxpJson(url)
            }
        }

        guard scriptsPath != nil || customScriptPath != nil else {
            throw ImportError.notAnRPGMakerGame
        }

        if let detectedVersion {
            try checkRuntimeSupport(detectedVersion)
        }

        if let scriptsPath {
            let normalized = scriptsPath.replacingOccurrences(of: "\\", with: "/")
            if let archiveURL, let scratchDir {
                try ensureFileExtracted(
                    relativePath: normalized,
                    gameRoot: url,
                    archiveURL: archiveURL,
                    scratchDir: scratchDir,
                    shouldCancel: shouldCancel
                )
            }
            try validateRGSSScripts(at: url, scriptsPath: normalized)
            return
        }

        if let customScriptPath {
            let normalized = customScriptPath.replacingOccurrences(of: "\\", with: "/")
            if let archiveURL, let scratchDir {
                try ensureFileExtracted(
                    relativePath: normalized,
                    gameRoot: url,
                    archiveURL: archiveURL,
                    scratchDir: scratchDir,
                    shouldCancel: shouldCancel
                )
            }
            try validateCustomScript(at: url, scriptPath: normalized)
            return
        }

        throw ImportError.notAnRPGMakerGame
    }

    private static func isLikelyGameRoot(
        _ url: URL,
        fm: FileManager
    ) -> Bool {
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }

        let lowercaseItems = items.map { $0.lowercased() }
        if rgssVersionFromArchive(lowercaseItems) != nil {
            return true
        }

        if lowercaseItems.contains("mkxp.json"), customScriptPath(url) != nil {
            return true
        }

        for item in items where item.lowercased().hasSuffix(".ini") {
            let iniURL = url.appendingPathComponent(item)
            if parseIniScripts(iniURL) != nil {
                return true
            }
        }

        return false
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
        preferredGameRootRelativePath: String? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: scratchDir.path) {
            try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        }

        let preferredRoot = normalizedRelativePath(preferredGameRootRelativePath)

        // State tracked during the walk. The walk stops early
        // when any of these prove the game is valid:
        //   1. RGSS archive marker (`.rgssad`/`.rgss2a`/`.rgss3a`)
        //      at any candidate game root - its name alone is
        //      sufficient.
        //   2. Both `Game.ini` AND a `Data/Scripts.*` below that
        //      same root. Only the canonical RPG Maker config file
        //      counts toward the stop predicate - Windows metadata
        //      like `desktop.ini` or tool configs like `Editor.ini`
        //      must not short-circuit the walk before `Game.ini`
        //      is reached (Perseida ships both).
        //
        // `mkxp.json` still gets extracted for mkxp-only games, but
        // it is NOT enough to short-circuit: many XP games ship an
        // auxiliary mkxp.json without `customScript`, so stopping on
        // `mkxp.json` + `Data/Scripts.*` can miss the later Game.ini
        // and falsely reject a valid game.
        var rgssArchiveVersion: RGSSVersion?
        var rgssArchiveRoot = ""
        var iniRoots = Set<String>()
        var scriptRoots = Set<String>()

        do {
            try ArchiveExtractor.extractSelective(
                archive: archiveURL,
                to: scratchDir,
                shouldCancel: shouldCancel,
                stopWhen: {
                    rgssArchiveVersion != nil || !iniRoots.isDisjoint(with: scriptRoots)
                },
                include: { path in
                    guard let entry = ArchiveEntryDescriptor(path) else { return false }

                    // Canonical RPG Maker config only. Other `.ini`
                    // files at the game root (desktop.ini, Editor.ini,
                    // MapMaker.ini, …) are ignored here so the walk
                    // does not stop before `Game.ini` is extracted.
                    if entry.isIni,
                        entry.lowercaseName == "game.ini",
                        matchesPreferredRoot(entry.parentPath, preferredRoot: preferredRoot)
                    {
                        iniRoots.insert(entry.parentPath)
                        return true
                    }
                    if entry.isMkxpJson,
                        matchesPreferredRoot(entry.parentPath, preferredRoot: preferredRoot)
                    {
                        return true
                    }
                    if let version = entry.archiveMarkerVersion,
                        matchesPreferredRoot(entry.parentPath, preferredRoot: preferredRoot)
                    {
                        rgssArchiveVersion = version
                        rgssArchiveRoot = entry.parentPath
                        return false
                    }

                    // Speculative scripts extraction: catches the
                    // default `Data/Scripts.*` layout. Games with a
                    // custom Scripts= path fall through to the second
                    // pass below.
                    if let scriptRoot = entry.defaultScriptsRoot,
                        matchesPreferredRoot(scriptRoot, preferredRoot: preferredRoot)
                    {
                        scriptRoots.insert(scriptRoot)
                        return true
                    }

                    // Artwork is deliberately NOT extracted here.
                    // Archives tend to be alphabetical, putting
                    // `Data/Scripts.*` before `Graphics/Titles/*`, so
                    // the walk's `stopWhen` predicate would fire before
                    // any artwork is reached. The full-extract pass
                    // later surfaces artwork via its per-file callback.

                    return false
                })
        } catch ArchiveExtractor.Error.cancelled {
            throw ArchiveExtractor.Error.cancelled
        } catch {
            throw ImportError.corruptZip(error.localizedDescription)
        }

        // Determine where the game root landed inside scratchDir
        // based on what got extracted (matches the
        // post-extraction logic that the full import uses later).
        let gameRoot: URL = {
            if let version = rgssArchiveVersion {
                _ = version
                return rgssArchiveRoot.isEmpty
                    ? scratchDir
                    : scratchDir.appendingPathComponent(rgssArchiveRoot, isDirectory: true)
            }
            if !preferredRoot.isEmpty {
                return scratchDir.appendingPathComponent(preferredRoot, isDirectory: true)
            }
            return locateGameRoot(in: scratchDir, fm: fm)
                ?? GameContainer.findGameRoot(in: scratchDir, fm: fm)
        }()

        // Fast path: RGSS-archived games were identified by name
        // during the walk.
        if let version = rgssArchiveVersion {
            try checkRuntimeSupport(version)
            return gameRoot
        }

        try validateResolvedGameRoot(
            at: gameRoot,
            archiveURL: archiveURL,
            scratchDir: scratchDir,
            shouldCancel: shouldCancel
        )

        return gameRoot
    }

    private static func importRootChoices(inArchive archiveURL: URL) throws -> [ImportRootChoice] {
        let fm = FileManager.default
        let scratchDir = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .archiveChoiceProbe,
            fm: fm
        )
        defer { try? fm.removeItem(at: scratchDir) }

        var rgssArchiveRoots: [String: RGSSVersion] = [:]
        try ArchiveExtractor.extractSelective(
            archive: archiveURL,
            to: scratchDir,
            include: { path in
                guard let entry = ArchiveEntryDescriptor(path) else { return false }

                if entry.isIni || entry.isMkxpJson {
                    return true
                }
                if let version = entry.archiveMarkerVersion {
                    rgssArchiveRoots[entry.parentPath] = version
                    return false
                }
                if entry.defaultScriptsRoot != nil {
                    return true
                }
                if entry.isExecutable {
                    return true
                }
                return entry.isPreviewTitleArtwork
            }
        )

        var choices: [ImportRootChoice] = []
        var firstArchiveError: Error?
        var firstMeaningfulArchiveError: Error?

        do {
            choices = try importRootChoices(
                inDirectory: scratchDir,
                fallbackRootName: archiveURL.deletingPathExtension().lastPathComponent,
                archiveURL: archiveURL,
                scratchDir: scratchDir
            )
        } catch {
            rememberValidationError(
                error,
                firstError: &firstArchiveError,
                firstMeaningfulError: &firstMeaningfulArchiveError
            )
        }

        let existing = Set(choices.map(\.relativePath))
        for (relativePath, version) in rgssArchiveRoots
        where !existing.contains(normalizedRelativePath(relativePath)) {
            do {
                try checkRuntimeSupport(version)
            } catch {
                rememberValidationError(
                    error,
                    firstError: &firstArchiveError,
                    firstMeaningfulError: &firstMeaningfulArchiveError
                )
                continue
            }

            let normalized = normalizedRelativePath(relativePath)
            let title =
                normalized.isEmpty
                ? archiveURL.deletingPathExtension().lastPathComponent
                : (normalized as NSString).lastPathComponent
            let subtitle = normalized.isEmpty ? "/" : normalized
            let artwork = previewArtwork(at: scratchDir, relativePath: normalized)
            choices.append(
                ImportRootChoice(
                    relativePath: normalized,
                    title: title,
                    subtitle: subtitle,
                    artwork: artwork
                )
            )
        }

        if choices.isEmpty {
            throw firstMeaningfulArchiveError ?? firstArchiveError ?? ImportError.notAnRPGMakerGame
        }
        return sortImportRootChoices(choices)
    }

    private static func importRootChoices(
        inDirectory directoryURL: URL,
        fallbackRootName: String,
        archiveURL: URL?,
        scratchDir: URL?
    ) throws -> [ImportRootChoice] {
        let candidates = discoverLikelyGameRoots(in: directoryURL)
        var choices: [ImportRootChoice] = []
        var firstValidationError: Error?
        var firstMeaningfulValidationError: Error?

        for root in candidates {
            do {
                try validateResolvedGameRoot(
                    at: root,
                    archiveURL: archiveURL,
                    scratchDir: scratchDir
                )
            } catch {
                rememberValidationError(
                    error,
                    firstError: &firstValidationError,
                    firstMeaningfulError: &firstMeaningfulValidationError
                )
                continue
            }

            let relativePath = relativePath(from: directoryURL, to: root)
            let title =
                GameINI.parseINIValue(at: root, section: "game", key: "title")
                ?? root.lastPathComponent
            let subtitle = relativePath.isEmpty ? fallbackRootName : relativePath
            choices.append(
                ImportRootChoice(
                    relativePath: relativePath,
                    title: title,
                    subtitle: subtitle,
                    artwork: previewArtwork(at: directoryURL, relativePath: relativePath)
                )
            )
        }

        if choices.isEmpty {
            throw firstMeaningfulValidationError
                ?? firstValidationError
                ?? ImportError.notAnRPGMakerGame
        }
        return sortImportRootChoices(choices)
    }

    private static func sortImportRootChoices(_ choices: [ImportRootChoice]) -> [ImportRootChoice] {
        choices.sorted { lhs, rhs in
            let lhsDepth = lhs.relativePath.isEmpty ? 0 : lhs.relativePath.split(separator: "/").count
            let rhsDepth = rhs.relativePath.isEmpty ? 0 : rhs.relativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func matchesPreferredRoot(_ root: String, preferredRoot: String) -> Bool {
        guard !preferredRoot.isEmpty else { return true }
        return preferredRoot.caseInsensitiveCompare(root) == .orderedSame
    }

    private static func rememberValidationError(
        _ error: Error,
        firstError: inout Error?,
        firstMeaningfulError: inout Error?
    ) {
        if firstError == nil {
            firstError = error
        }
        if firstMeaningfulError == nil, isMeaningfulValidationError(error) {
            firstMeaningfulError = error
        }
    }

    private static func isMeaningfulValidationError(_ error: Error) -> Bool {
        guard let importError = error as? ImportError else { return true }
        if case .notAnRPGMakerGame = importError {
            return false
        }
        return true
    }

    private static func normalizedRelativePath(_ relativePath: String?) -> String {
        guard let relativePath else { return "" }
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if normalized == "." { return "" }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath != basePath else { return "" }
        guard targetPath.hasPrefix(basePath + "/") else { return targetURL.lastPathComponent }
        return String(targetPath.dropFirst(basePath.count + 1))
    }

    private static func rgssVersion(fromArchiveMarker markerName: String) -> RGSSVersion? {
        let lower = markerName.lowercased()
        if lower.hasSuffix(".rgssad") { return .xp }
        if lower.hasSuffix(".rgss2a") { return .vx }
        if lower.hasSuffix(".rgss3a") { return .vxAce }
        return nil
    }

    private static func previewArtwork(
        at baseURL: URL,
        relativePath: String
    ) -> ImportRootChoiceArtwork? {
        let rootURL =
            normalizedRelativePath(relativePath).isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(relativePath, isDirectory: true)

        if let exeArtwork = previewExecutableArtwork(in: rootURL) {
            return exeArtwork
        }
        return previewTitlesArtwork(in: rootURL)
    }

    private static func previewExecutableArtwork(in gameRoot: URL) -> ImportRootChoiceArtwork? {
        let fm = FileManager.default
        let exeItems =
            gameRoot
            .directoryEntries(matchingExtensions: ["exe"], fm: fm)
            .map(\.lastPathComponent)
        let ordered: [String]
        if let canonical = exeItems.first(where: { $0.lowercased() == "game.exe" }) {
            ordered = [canonical] + exeItems.sorted().filter { $0 != canonical }
        } else {
            ordered = exeItems.sorted()
        }

        for item in ordered {
            if item.lowercased() != "game.exe",
                ExecutableIconExtractor.isUtilityExecutable(filename: item)
            {
                continue
            }

            let exeURL = gameRoot.appendingPathComponent(item)
            guard let image = ExecutableIconExtractor.extractIcon(fromExecutableAt: exeURL) else {
                continue
            }

            if let png = image.pngData() {
                return .icon(png)
            }
        }

        return nil
    }

    private static func previewTitlesArtwork(in gameRoot: URL) -> ImportRootChoiceArtwork? {
        let titlesDir = gameRoot.appendingPathComponent("Graphics/Titles")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: titlesDir.path) else {
            return nil
        }

        for item in items.sorted() {
            let ext = (item as NSString).pathExtension.lowercased()
            if previewImageExtensions.contains(ext) {
                let path = titlesDir.appendingPathComponent(item)
                if let data = try? Data(contentsOf: path, options: .mappedIfSafe) {
                    return .image(data)
                }
            }
        }
        return nil
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

        let wrapperPrefix: String? =
            archivePrefix(for: gameRoot, under: scratchDir)

        var extracted = false
        try ArchiveExtractor.extractSelective(
            archive: archiveURL,
            to: scratchDir,
            shouldCancel: shouldCancel,
            stopWhen: { extracted },
            include: { rawPath in
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
        )
    }

    private static func archivePrefix(for gameRoot: URL, under scratchDir: URL) -> String? {
        let scratchPath = scratchDir.standardizedFileURL.path
        let gamePath = gameRoot.standardizedFileURL.path
        guard gamePath != scratchPath else { return nil }
        guard gamePath.hasPrefix(scratchPath + "/") else { return nil }

        let relative = String(gamePath.dropFirst(scratchPath.count + 1))
        guard !relative.isEmpty else { return nil }
        return relative + "/"
    }

    /// Detected RGSS version: 1 = XP, 2 = VX, 3 = VX Ace
    private enum RGSSVersion: Int {
        case xp = 1
        case vx = 2
        case vxAce = 3
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
            let ver = json["rgssVersion"] as? Int
        else {
            return nil
        }
        return RGSSVersion(rawValue: ver)
    }

    /// Returns the detected RGSS version and the raw scripts path.
    private static func parseIniScripts(_ iniURL: URL) -> (RGSSVersion, String)? {
        guard let value = GameINI.parseINIValue(in: iniURL, section: "game", key: "scripts") else {
            return nil
        }
        let lower = value.lowercased()
        let version: RGSSVersion
        if lower.hasSuffix(".rvdata2") {
            version = .vxAce
        } else if lower.hasSuffix(".rvdata") {
            version = .vx
        } else {
            version = .xp
        }
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
            header[2] == 0x5B
        else {
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
            !script.isEmpty
        else {
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
        case .xp: label = "RPG Maker XP (RGSS1)"
        case .vx: label = "RPG Maker VX (RGSS2)"
        case .vxAce: label = "RPG Maker VX Ace (RGSS3)"
        }
        throw ImportError.unsupportedRuntime(
            "This game requires \(label), which isn't supported right now."
        )
    }
}

struct ImportRootChoiceArtwork: Hashable {
    private let kind: ImportRootChoiceArtworkKind

    private init(_ kind: ImportRootChoiceArtworkKind) {
        self.kind = kind
    }

    static func image(_ data: Data) -> Self {
        Self(.image(data))
    }

    static func icon(_ data: Data) -> Self {
        Self(.icon(data))
    }

    var imageData: Data? {
        if case .image(let data) = kind { return data }
        return nil
    }

    var iconData: Data? {
        if case .icon(let data) = kind { return data }
        return nil
    }
}

private enum ImportRootChoiceArtworkKind: Hashable {
    case image(Data)
    case icon(Data)
}
