import Foundation
import GameProbe

/// Read model for the game library: scan containers on disk and
/// build `GameSnapshot` values that the main actor merges into the
/// live `GameEntry` models.
enum GameCatalog {

    /// Fast first-pass scan for launch. Builds displayable entries
    /// (title, metadata, already-materialized artwork) but skips the
    /// expensive per-container work: validation, orphan cleanup, PE
    /// icon extraction, and Ruby script-profile detection. Entries
    /// come back `.ready` even if a full scan would mark them
    /// `.invalid`. The full `scanGames` pass that follows corrects
    /// status and artwork in place.
    nonisolated static func quickScanGames(
        fm: FileManager = .default,
        isImportInFlight: @Sendable (String) -> Bool = { _ in false },
        isDeletionInFlight: @Sendable (String) -> Bool = { _ in false }
    ) -> [GameSnapshot] {
        var entries: [GameSnapshot] = []

        for container in GameContainer.discover() {
            if isImportInFlight(container.id) { continue }
            if isDeletionInFlight(container.id) { continue }
            // Skip orphaned containers (no Game/ subdir) instead of
            // deleting them. The full pass owns cleanup.
            guard fm.fileExists(atPath: container.gameURL.path) else { continue }
            if let entry = buildSnapshot(from: container, fm: fm, quick: true) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    /// Both closures must read LIVE state (not a snapshot from
    /// when the scan was scheduled): the scan takes seconds. An
    /// in-place update registered mid-scan would otherwise have
    /// its staging directory swept - and its container surfaced -
    /// while the import task is still working on it. A delete
    /// registered mid-scan looks like a half-removed orphan; the
    /// cleanup below would then race the delete's own removal and
    /// rescue-drain torn directories into `Data/`.
    nonisolated static func scanGames(
        fm: FileManager = .default,
        cleanupInvalid: Bool,
        isImportInFlight: @Sendable (String) -> Bool = { _ in false },
        isDeletionInFlight: @Sendable (String) -> Bool = { _ in false }
    ) -> [GameSnapshot] {
        var entries: [GameSnapshot] = []

        for container in GameContainer.discover() {
            if isImportInFlight(container.id) { continue }
            if isDeletionInFlight(container.id) { continue }

            // No import is in flight for this container (checked
            // live above), so any update-staging directory is a
            // leftover from a crashed in-place update - restore
            // and/or sweep it.
            GameImporter.cleanupStaleUpdateStaging(in: container)

            // A container without a `Game/` subdirectory never finished
            // importing (e.g. the app was killed mid-extract, leaving only
            // the `Metadata/` sidecar dir behind). It can't become a real
            // game, so drop it instead of surfacing an "Unknown Game" card.
            // Live imports are excluded by the checks above, so anything
            // reaching here with no `Game/` is a genuine orphan.
            let gameDirExists = fm.fileExists(atPath: container.gameURL.path)
            if !gameDirExists {
                // Re-check the live sets right before the delete:
                // the loop-entry check can be minutes stale on a
                // long scan, and this cleanup is the one delete
                // that never registers itself.
                if isImportInFlight(container.id) || isDeletionInFlight(container.id) {
                    continue
                }
                // Same save rescue as user-initiated deletes: a
                // pre-0.5 orphan can still hold the only copy of
                // its saves in UserData/. Rescue first (UserData
                // into Data/, portable saves into Rescued Saves/);
                // a failed rescue keeps the container for the next
                // scan instead of erasing the saves.
                if DataDirectory.rescueUserDataBeforeDeletion(of: container) {
                    NSLog(
                        "[GameCatalog] Removing incomplete import container: %@",
                        container.folderName)
                    try? container.deleteAll()
                } else {
                    NSLog(
                        "[GameCatalog] Keeping incomplete container %@: save rescue failed",
                        container.folderName)
                }
                continue
            }

            let isValid = (try? GameImportValidator.validate(container.gameURL)) != nil

            if !isValid {
                if cleanupInvalid {
                    if isImportInFlight(container.id) || isDeletionInFlight(container.id) {
                        continue
                    }
                    if DataDirectory.rescueUserDataBeforeDeletion(of: container) {
                        NSLog(
                            "[GameCatalog] Removing invalid game container: %@",
                            container.folderName)
                        try? container.deleteAll()
                        continue
                    }
                    NSLog(
                        "[GameCatalog] Keeping invalid container %@: save rescue failed",
                        container.folderName)
                }
                if var entry = buildSnapshot(from: container, fm: fm) {
                    entry.status = .invalid
                    entries.append(entry)
                }
                continue
            }

            if let entry = buildSnapshot(from: container, fm: fm) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    /// `quick: true` builds an entry from cheap reads only (INI
    /// title, metadata.json, artwork that already exists on disk),
    /// skipping PE icon extraction and script-profile detection.
    /// Used by `quickScanGames` for the launch fast path.
    nonisolated static func buildSnapshot(
        from container: GameContainer,
        fm: FileManager = .default,
        quick: Bool = false
    ) -> GameSnapshot? {
        let iniTitle =
            GameINI.parseINIValue(at: container.gameURL, section: "game", key: "title")
            ?? "Unknown Game"
        let defaultArtwork = quick ? quickFindArtwork(in: container) : findArtwork(in: container)

        var metadata = GameMetadata.load(from: container)
        if !quick {
            let settings = GameSettings.load(from: container.empoStateURL)
            if settings.allowsRubyAutoDetectRefresh {
                metadata.refreshDetectedProfile(in: container)
            }
        }

        let baseTitle = metadata.baseTitle ?? iniTitle
        let title = metadata.customTitle ?? baseTitle
        let artworkPath = metadata.customArtworkPath(in: container) ?? defaultArtwork
        let engineTitle: String? = {
            guard metadata.customTitle != nil else { return nil }
            return titlesMeaningfullyDiffer(title, iniTitle) ? iniTitle : nil
        }()

        return GameSnapshot(
            id: container.id,
            container: container,
            title: title,
            artworkPath: artworkPath,
            engineTitle: engineTitle,
            lastPlayed: metadata.lastPlayed,
            dateAdded: metadata.dateAdded,
            totalPlayTime: metadata.totalPlayTime
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

    /// Artwork resolution minus the expensive fallback: checks the
    /// exe-icon sidecar and Graphics/Titles, but never runs the PE
    /// resource extraction `findArtwork` may perform for games
    /// imported before sidecars existed.
    nonisolated static func quickFindArtwork(in container: GameContainer) -> String? {
        let sidecar = container.exeIconSidecarURL
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return sidecar.path
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
