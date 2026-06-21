import Foundation

/// Read model for the game library: scan containers on disk and
/// build `GameEntry` values for the UI.
enum GameCatalog {

    nonisolated static func scanGames(
        fm: FileManager = .default,
        cleanupInvalid: Bool,
        skipIDs: Set<String> = []
    ) -> [GameEntry] {
        var entries: [GameEntry] = []

        for container in GameContainer.discover() {
            if skipIDs.contains(container.id) { continue }

            let gameDirExists = fm.fileExists(atPath: container.gameURL.path)
            let isValid =
                gameDirExists
                && (try? GameImportValidator.validate(container.gameURL)) != nil

            if !isValid {
                if cleanupInvalid {
                    NSLog(
                        "[GameCatalog] Removing invalid game container: %@",
                        container.folderName)
                    try? container.deleteAll()
                    continue
                }
                if var entry = buildGameEntry(from: container, fm: fm) {
                    entry.status = .invalid
                    entries.append(entry)
                }
                continue
            }

            if let entry = buildGameEntry(from: container, fm: fm) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    nonisolated static func buildGameEntry(
        from container: GameContainer,
        fm: FileManager = .default
    ) -> GameEntry? {
        let iniTitle = GameEntry.parseINITitle(at: container.gameURL) ?? "Unknown Game"
        let defaultArtwork = findArtwork(in: container)

        let settings = GameSettings.load(from: container.empoStateURL)
        var metadata = GameMetadata.load(from: container)
        if settings.allowsRubyAutoDetectRefresh {
            metadata.refreshDetectedProfile(in: container)
        }

        let baseTitle = metadata.baseTitle ?? iniTitle
        let title = metadata.customTitle ?? baseTitle
        let artworkPath = metadata.customArtworkPath(in: container) ?? defaultArtwork
        let engineTitle: String? = {
            guard metadata.customTitle != nil else { return nil }
            return titlesMeaningfullyDiffer(title, iniTitle) ? iniTitle : nil
        }()

        return GameEntry(
            id: container.id,
            container: container,
            title: title,
            artworkPath: artworkPath,
            engineTitle: engineTitle,
            lastPlayed: metadata.lastPlayed,
            dateAdded: metadata.dateAdded
        )
    }

    nonisolated static func titlesMeaningfullyDiffer(_ a: String, _ b: String) -> Bool {
        let folded: (String) -> String = { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
        }
        return folded(a) != folded(b)
    }

    nonisolated static func findArtwork(in container: GameContainer) -> String? {
        let fm = FileManager.default
        let sidecar = container.exeIconSidecarURL
        if fm.fileExists(atPath: sidecar.path) {
            return sidecar.path
        }
        if let sidecarPath = ExecutableIconExtractor.writeSidecarIfPossible(in: container) {
            return sidecarPath
        }
        return findTitlesArtwork(in: container.gameURL)
    }

    nonisolated static func findFolderImportArtwork(at url: URL) -> String? {
        findTitlesArtwork(in: url)
    }

    nonisolated private static func findTitlesArtwork(in gameURL: URL) -> String? {
        let titlesDir = gameURL.appendingPathComponent("Graphics/Titles")
        guard
            let items = try? FileManager.default
                .contentsOfDirectory(atPath: titlesDir.path)
        else { return nil }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]
        for item in items.sorted() {
            let ext = (item as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                return titlesDir.appendingPathComponent(item).path
            }
        }
        return nil
    }
}
