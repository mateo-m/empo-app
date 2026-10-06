import Foundation

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

    /// Returns the core that runs the game at `url`.
    @discardableResult
    private static func validateResolvedGameRoot(
        at url: URL,
        archiveURL: URL? = nil,
        scratchDir: URL? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> any GameCore {
        // Which cores this build carries is not a property of these
        // files. GameCatalog calls this on every scan and deletes a
        // container it calls invalid, so a missing core must not fail
        // here. ImportPipeline and GameLibraryView refuse instead.
        guard let core = GameCores.core(forGameAt: url) else { throw ImportError.notAGame }
        try core.validateGameRoot(url) { relativePath in
            guard let archiveURL, let scratchDir else { return }
            try ensureFileExtracted(
                relativePath: relativePath,
                gameRoot: url,
                archiveURL: archiveURL,
                scratchDir: scratchDir,
                shouldCancel: shouldCancel
            )
        }
        return core
    }

    private static func isLikelyGameRoot(
        _ url: URL,
        fm: FileManager
    ) -> Bool {
        GameCores.core(forGameAt: url, fileManager: fm) != nil
    }

    private static func importRootChoices(inArchive archiveURL: URL) throws -> ArchiveProbeResult {
        let fm = FileManager.default
        let scratchDir = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .archiveChoiceProbe,
            fm: fm
        )
        defer { try? fm.removeItem(at: scratchDir) }

        var inventory = ArchiveExtractor.Inventory()
        // A core marks the folder of an entry that is too large to
        // extract for the probe. The value is the core and the entry.
        var markedRoots: [String: (core: any GameCore, marker: String)] = [:]
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
                guard let entry = ArchiveEntry(path) else { return false }
                // The preview reads the icon of the game's .exe.
                if entry.lowercaseName.hasSuffix(".exe") { return true }
                for core in GameCores.all {
                    switch core.archiveEntryUse(entry) {
                    case .skip: continue
                    case .extract: return true
                    case .markRoot:
                        markedRoots[entry.parentPath] = (core, entry.lowercaseName)
                        return false
                    }
                }
                return false
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
        for (relativePath, mark) in markedRoots
        where !existing.contains(normalizedRelativePath(relativePath)) {
            do {
                try mark.core.validateMarkedRoot(marker: mark.marker)
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
            let artwork = previewArtwork(at: scratchDir, relativePath: normalized, core: mark.core)
            choices.append(
                ImportRootChoice(
                    relativePath: normalized,
                    title: title,
                    subtitle: subtitle,
                    artwork: artwork,
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
            let core: any GameCore
            do {
                core = try validateResolvedGameRoot(
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
            let declaredTitle = core.title(at: root) ?? jgpManifestName(at: root)
            let title =
                declaredTitle
                ?? (relativePath.isEmpty ? fallbackRootName : root.lastPathComponent)
            let subtitle = relativePath.isEmpty ? fallbackRootName : relativePath
            choices.append(
                ImportRootChoice(
                    relativePath: relativePath,
                    title: title,
                    subtitle: subtitle,
                    artwork: previewArtwork(at: directoryURL, relativePath: relativePath, core: core),
                    canTakeTheSourceName: declaredTitle == nil && !relativePath.isEmpty
                        && core.usesFolderName
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

    /// Renames a single nameless root after the source the user picked,
    /// for a core whose games have no title of their own.
    ///
    /// A release often nests the game in a wrapper folder, and the
    /// wrapper is named after the layout instead of the game: the
    /// Windows release of Edelweiss Chronicles ships its game in `app/`
    /// next to `patcher/`, so the library showed "app". The leaf name
    /// has one job, to tell two games in one source apart. With one
    /// root it carries nothing, and the name of what the user picked is
    /// always closer to the truth.
    ///
    /// The title becomes the container folder name, and the importer
    /// matches an installed game by that folder
    /// (`ImportNameResolution.resolve`), so a title that changes
    /// between two Empo versions installs the same game twice. PSDK
    /// support arrived with this naming, so no PSDK game can carry the
    /// older name. An RPG Maker game can, so its core keeps
    /// `usesFolderName` off.
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

    private static func previewArtwork(
        at baseURL: URL,
        relativePath: String,
        core: any GameCore
    ) -> ImportRootChoiceArtwork? {
        let rootURL =
            normalizedRelativePath(relativePath).isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(relativePath, isDirectory: true)

        if let exeArtwork = previewExecutableArtwork(in: rootURL) {
            return exeArtwork
        }
        return core.titlePicture(at: rootURL)
            .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            .map(ImportRootChoiceArtwork.image)
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
