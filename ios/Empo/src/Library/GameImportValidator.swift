import Foundation
import GameProbe

enum GameImportValidator {

    enum ImportError: LocalizedError {
        case unzipFailed
        case corruptZip(String)
        case notAGame
        case unsupportedRuntime(String)
        case missingScripts(String)
        case invalidScripts(String)
        // JoiPlay .jgp specific
        case invalidJgpManifest

        var errorDescription: String? {
            switch self {
            case .unzipFailed:
                return "Empo couldn't unpack this archive. Download the game again, then import it."
            case .corruptZip:
                return "This archive is damaged. Download the game again, then import it."
            case .notAGame:
                return
                    "Empo found no game here. Pick the folder that contains Game.exe or Game.rb, then import again."
            case .unsupportedRuntime(let detail):
                return detail
            case .missingScripts:
                return
                    "This game is missing the script file it needs to run. Download the game again, then import it."
            case .invalidScripts:
                return "Empo can't read this game's script file. Download the game again, then import it."
            case .invalidJgpManifest:
                return "Empo can't read this JoiPlay archive. Download it again, then import it."
            }
        }
    }

    struct ImportRootChoice: Identifiable, Hashable {
        let relativePath: String
        let title: String
        let subtitle: String
        let artwork: ImportRootChoiceArtwork?
        /// True when the title above is only the name of the folder the
        /// game sits in, and taking the name of the source instead
        /// cannot rename an installed game. `nameLoneRootAfterSource`
        /// reads it.
        let canTakeTheSourceName: Bool

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

        /// The pair a PSDK game is known by. Both files go into the
        /// probe, because the check reads Game.yarb's first four bytes
        /// (`PsdkGame.isGameRoot`).
        var isPsdkMarker: Bool {
            lowercaseName == "game.rb" || lowercaseName == "game.yarb"
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

    struct ArchiveProbeResult: Sendable {
        let choices: [ImportRootChoice]
        let inventory: ArchiveExtractor.Inventory?
    }

    /// Throws ImportError on failure. Validates a folder already
    /// present on disk. Used for full extracted imports and for
    /// folder-based imports. Archives are validated during the
    /// resolution probe before import starts.
    static func validate(_ url: URL) throws {
        guard let gameRoot = locateGameRoot(in: url) else {
            throw ImportError.notAGame
        }
        try validateResolvedGameRoot(at: gameRoot)
    }

    static func importRootChoices(for sourceURL: URL) throws -> ArchiveProbeResult {
        if ArchiveExtractor.Format(extension: sourceURL.pathExtension) != nil {
            return try importRootChoices(inArchive: sourceURL)
        }
        let choices = try importRootChoices(
            inDirectory: sourceURL,
            fallbackRootName: sourceURL.lastPathComponent,
            archiveURL: nil,
            scratchDir: nil
        )
        return ArchiveProbeResult(
            choices: nameLoneRootAfterSource(
                choices, fallbackRootName: sourceURL.lastPathComponent),
            inventory: nil
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
            throw ImportError.notAGame
        }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw ImportError.notAGame
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ImportError.notAGame
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
        // Which core this build carries is not a property of these
        // files. GameCatalog calls this on every scan and deletes a
        // container it calls invalid, so a missing core must not fail
        // here. ImportPipeline and GameLibraryView refuse instead.
        //
        // A PSDK game carries none of what the checks below read: no
        // RGSS archive, no .ini with a Scripts entry, no Scripts file.
        // The PSDK core runs it, so no RGSS version applies either.
        if GameCoreKind.forGame(at: url) == .psdk { return }

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else {
            throw ImportError.notAGame
        }

        let lowercaseItems = items.map { $0.lowercased() }

        // 1. Check for an RGSS archive: definitive proof + version detection.
        //    When an archive is present, the scripts are packed inside it and
        //    can't be validated without decryption, so we check only the version.
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

        // 3. Check for mkxp.json. Only valid if it has a customScript
        //    (without customScript AND without a valid .ini, the engine
        //    won't know where to find scripts and will fail at runtime)
        var customScriptPath: String?
        if lowercaseItems.contains("mkxp.json") {
            customScriptPath = Self.customScriptPath(url)
            if scriptsPath == nil, customScriptPath == nil {
                throw ImportError.notAGame
            }
            if scriptsPath == nil {
                detectedVersion = rgssVersionFromMkxpJson(url)
            }
        }

        guard scriptsPath != nil || customScriptPath != nil else {
            throw ImportError.notAGame
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

        throw ImportError.notAGame
    }

    private static func isLikelyGameRoot(
        _ url: URL,
        fm: FileManager
    ) -> Bool {
        if PsdkGame.isGameRoot(url, fileManager: fm) { return true }

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

    private static func importRootChoices(inArchive archiveURL: URL) throws -> ArchiveProbeResult {
        let fm = FileManager.default
        let scratchDir = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .archiveChoiceProbe,
            fm: fm
        )
        defer { try? fm.removeItem(at: scratchDir) }

        var inventory = ArchiveExtractor.Inventory()
        var rgssArchiveRoots: [String: RGSSVersion] = [:]
        try ArchiveExtractor.extractSelective(
            archive: archiveURL,
            to: scratchDir,
            onEntry: { _, uncompressedSize in
                inventory.entryCount += 1
                if let size = uncompressedSize {
                    inventory.totalUncompressedBytes += size
                } else {
                    inventory.allSizesKnown = false
                }
            },
            include: { path in
                guard let entry = ArchiveEntryDescriptor(path) else { return false }

                if entry.isIni || entry.isMkxpJson || entry.isPsdkMarker {
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
        try EnigmaVirtualBoxImport.unpackProbeFiles(under: scratchDir)

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
                    artwork: artwork,
                    // An RGSS archive root, so the name stays as it was.
                    canTakeTheSourceName: false
                )
            )
        }

        if choices.isEmpty {
            throw firstMeaningfulArchiveError ?? firstArchiveError ?? ImportError.notAGame
        }
        return ArchiveProbeResult(
            choices: sortImportRootChoices(
                nameLoneRootAfterSource(
                    choices,
                    fallbackRootName: archiveURL.deletingPathExtension().lastPathComponent
                )
            ),
            inventory: inventory
        )
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
            // Title priority matches the migration's chain (INI
            // title, then JGP manifest name, then folder name). A
            // re-import of a .jgp whose game ships no INI must
            // adopt the container the migration named after the
            // manifest - an archive-name fallback here would mint
            // a second container for the same game.
            let declaredTitle = GameINI.gameTitle(at: root) ?? jgpManifestName(at: root)
            let title =
                declaredTitle
                ?? (relativePath.isEmpty ? fallbackRootName : root.lastPathComponent)
            let subtitle = relativePath.isEmpty ? fallbackRootName : relativePath
            choices.append(
                ImportRootChoice(
                    relativePath: relativePath,
                    title: title,
                    subtitle: subtitle,
                    artwork: previewArtwork(at: directoryURL, relativePath: relativePath),
                    canTakeTheSourceName: declaredTitle == nil && !relativePath.isEmpty
                        && PsdkGame.isGameRoot(root)
                )
            )
        }

        if choices.isEmpty {
            throw firstMeaningfulValidationError
                ?? firstValidationError
                ?? ImportError.notAGame
        }
        return sortImportRootChoices(choices)
    }

    private static func jgpManifestName(at root: URL) -> String? {
        guard let name = Jgp.parseBundle(at: root)?.manifest.name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Renames a single nameless PSDK root after the source the user
    /// picked.
    ///
    /// A release often nests the game in a wrapper folder, and the
    /// wrapper is named after the layout instead of the game: the
    /// Windows release of Edelweiss Chronicles ships its game in `app/`
    /// next to `patcher/`, so the library showed "app". The leaf name
    /// has one job, to tell two games in one source apart. With one
    /// root it carries nothing, and the name of what the user picked is
    /// always closer to the truth.
    ///
    /// PSDK games only. The title becomes the container folder name,
    /// and the importer matches an installed game by that folder
    /// (`ImportNameResolution.resolve`), so a title that changes
    /// between two Empo versions installs the same game twice. PSDK
    /// support arrives with this naming, so no PSDK game can carry the
    /// older name. An RPG Maker game can, and keeps it.
    private static func nameLoneRootAfterSource(
        _ choices: [ImportRootChoice],
        fallbackRootName: String
    ) -> [ImportRootChoice] {
        guard choices.count == 1, let only = choices.first, only.canTakeTheSourceName else {
            return choices
        }
        return [
            ImportRootChoice(
                relativePath: only.relativePath,
                title: fallbackRootName,
                subtitle: only.subtitle,
                artwork: only.artwork,
                canTakeTheSourceName: false
            )
        ]
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
        if case .notAGame = importError {
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
        // Game.ini uses backslashes (Windows paths). Convert them to forward slashes.
        let normalized = scriptsPath.replacingOccurrences(of: "\\", with: "/")
        let fileURL = gameDir.appendingPathComponent(normalized)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.missingScripts(normalized)
        }

        // Ruby Marshal format: the first 2 bytes are the version (0x04,
        // 0x08), and the third byte is the type tag. 0x5B means Array.
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
        // The mask depends on the Ruby versions the core carries: Ruby
        // 1.8 alone runs RGSS1 and RGSS2, and Ruby 3.x with the syntax
        // transform runs all three.
        let mask = BuiltInGameCore.rgssVersionMask
        // Zero means this build carries no RPG Maker core. The files are
        // still a game, so say nothing here and let ImportPipeline and
        // GameLibraryView name the missing core.
        guard mask != 0 else { return }
        let bit = 1 << (version.rawValue - 1)
        if mask & bit != 0 { return }

        let label: String
        switch version {
        case .xp: label = "RPG Maker XP (RGSS1)"
        case .vx: label = "RPG Maker VX (RGSS2)"
        case .vxAce: label = "RPG Maker VX Ace (RGSS3)"
        }
        throw ImportError.unsupportedRuntime(
            "This game requires \(label). Empo does not support it right now."
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
