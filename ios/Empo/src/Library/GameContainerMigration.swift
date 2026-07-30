import Foundation
import GameProbe

/// Launch-time migration from the pre-v0.5 `<uuid>-<slug>` container
/// directories to title-based directories (`Games/Pokémon Uranium/`
/// instead of `Games/3F2504E0-...-pokemon-uranium/`).
///
/// The library's invariant after this migration is **one container
/// per title**. Folder names must be exactly the game's INI title
/// because some games derive their save/data locations from the
/// title they declare in their INI - a suffixed duplicate like
/// `Testing 2` would still call itself "Testing" and read the other
/// copy's data. So when several legacy imports resolve to the same
/// title, the copy played most recently (then the most recently
/// added) keeps the canonical name, and every other copy moves -
/// whole and untouched, saves included - to the Files-visible
/// `Documents/Duplicate Games/` folder, where the user can recover
/// save files or re-import.
///
/// Renaming the directory also changes the container id (the id IS
/// the folder name now), so the per-game UserDefaults key families
/// (`controlsLayout.<id>`, `controllerMap.<id>`) move with the
/// canonical copy. All other per-game state (saves, settings,
/// metadata, logs, controls manifest) lives inside the container
/// and travels with the rename for free.
///
/// Must run before anything enumerates `GameContainer.discover()`
/// (library scan, save migration, crash tracker), so both singleton
/// entry points (`GameLibrary.init`, `AppState.init`) call
/// `migrateLegacyContainersIfNeeded()` first. Idempotent: once no
/// legacy names remain the scan is a cheap directory listing.
enum GameContainerMigration {

    /// Where duplicate legacy imports land. A sibling of `Games/`
    /// so discovery never surfaces them as library entries, and
    /// non-hidden so the user can reach them in the Files app.
    static let duplicatesRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Duplicate Games", isDirectory: true)

    @MainActor private static var didRunThisLaunch = false

    @MainActor
    static func migrateLegacyContainersIfNeeded() {
        guard !didRunThisLaunch else { return }
        didRunThisLaunch = true
        migrateLegacyContainers()
    }

    private struct LegacyCandidate {
        let url: URL
        let legacyID: String
        let preferredName: String
        let lastPlayed: Date
        let dateAdded: Date
    }

    static func migrateLegacyContainers(fm: FileManager = .default) {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: GameContainer.rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        // Names already in use by post-migration containers,
        // compared case-insensitively so two titles differing only
        // in case can't produce directories that collide on a
        // case-insensitive filesystem.
        var takenNames = Set<String>()
        var candidates: [LegacyCandidate] = []

        for url in entries {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            guard isDirectory else { continue }

            let name = url.lastPathComponent
            guard let legacyID = GameContainer.legacyUUIDPrefix(folderName: name) else {
                takenNames.insert(name.lowercased())
                continue
            }

            let metadata = GameMetadata.load(from: GameContainer(url: url))
            candidates.append(
                LegacyCandidate(
                    url: url,
                    legacyID: legacyID,
                    preferredName: GameFolderName.sanitize(migrationTitle(forLegacyContainerAt: url)),
                    lastPlayed: metadata.lastPlayed ?? .distantPast,
                    dateAdded: metadata.dateAdded ?? .distantPast
                ))
        }

        // One container per title: within a title group, the most
        // recently played (then most recently added) copy is the
        // one the user cares about, so it keeps the canonical name
        // - and thereby stays the target of future update imports.
        let groups = Dictionary(grouping: candidates) { $0.preferredName.lowercased() }
        for (nameKey, group) in groups {
            let ordered = group.sorted { lhs, rhs in
                if lhs.lastPlayed != rhs.lastPlayed { return lhs.lastPlayed > rhs.lastPlayed }
                return lhs.dateAdded > rhs.dateAdded
            }

            // The title may already belong to a post-migration
            // container (interrupted earlier run): every remaining
            // legacy copy is then a duplicate of it.
            var titleClaimed = takenNames.contains(nameKey)

            for candidate in ordered {
                if titleClaimed {
                    quarantineDuplicate(candidate, fm: fm)
                    continue
                }

                let destination = GameContainer.rootURL
                    .appendingPathComponent(candidate.preferredName, isDirectory: true)
                do {
                    try fm.moveItem(at: candidate.url, to: destination)
                } catch {
                    // Leave the tree under its legacy name; the next
                    // launch retries. Discovery still surfaces it
                    // (any directory is a container), so the game
                    // stays playable meanwhile.
                    NSLog(
                        "[GameContainerMigration] Failed to rename %@ -> %@: %@",
                        candidate.url.lastPathComponent,
                        candidate.preferredName,
                        error.localizedDescription)
                    continue
                }

                titleClaimed = true
                takenNames.insert(nameKey)
                migrateUserDefaultsKeys(fromID: candidate.legacyID, toID: candidate.preferredName)
                NSLog(
                    "[GameContainerMigration] Renamed %@ -> %@",
                    candidate.url.lastPathComponent,
                    candidate.preferredName)
            }
        }
    }

    /// Move a duplicate legacy import - whole, saves included - out
    /// of the library into `Duplicate Games/`. Nothing is merged or
    /// deleted; the user resolves duplicates manually in Files. The
    /// moved name is recorded so the library can show the one-time
    /// explanatory alert (`pendingDuplicateNoticeNames`).
    private static func quarantineDuplicate(_ candidate: LegacyCandidate, fm: FileManager) {
        try? fm.createDirectory(at: duplicatesRootURL, withIntermediateDirectories: true)
        excludeFromBackup(duplicatesRootURL)

        let name = GameFolderName.uniqueName(preferring: candidate.preferredName) { proposed in
            fm.fileExists(atPath: duplicatesRootURL.appendingPathComponent(proposed).path)
        }
        let destination = duplicatesRootURL.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.moveItem(at: candidate.url, to: destination)
            recordQuarantinedName(name)
            NSLog(
                "[GameContainerMigration] Moved duplicate %@ -> Duplicate Games/%@",
                candidate.url.lastPathComponent,
                name)
        } catch {
            NSLog(
                "[GameContainerMigration] Failed to quarantine duplicate %@: %@",
                candidate.url.lastPathComponent,
                error.localizedDescription)
        }
    }

    // MARK: - Duplicate notice

    /// Folder names (inside `Duplicate Games/`) moved by this or a
    /// previous launch whose explanatory alert the user hasn't seen
    /// yet. Persisted in UserDefaults so a force-quit before the
    /// library appears doesn't swallow the notice.
    static func pendingDuplicateNoticeNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: DefaultsKey.pendingDuplicateGameNames) ?? []
    }

    /// The user has seen the alert.
    static func clearPendingDuplicateNotice() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingDuplicateGameNames)
    }

    private static func recordQuarantinedName(_ name: String) {
        var names = pendingDuplicateNoticeNames()
        names.append(name)
        UserDefaults.standard.set(names, forKey: DefaultsKey.pendingDuplicateGameNames)
    }

    /// Same backup policy as `Games/`: game trees are large and
    /// re-importable, so keep them out of users' iCloud quota.
    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    /// Title for a legacy container, in the same priority the
    /// import pipeline now uses for naming: the INI title, then the
    /// import-time base title (JGP manifest name), then the old
    /// folder slug as a last resort.
    private static func migrationTitle(forLegacyContainerAt url: URL) -> String {
        let container = GameContainer(url: url)

        if let iniTitle = GameINI.parseINIValue(
            at: container.gameURL, section: "game", key: "title")
        {
            return iniTitle
        }
        if let baseTitle = GameMetadata.load(from: container).baseTitle {
            return baseTitle
        }
        return legacySlugTitle(fromFolderName: url.lastPathComponent)
            ?? GameFolderName.fallback
    }

    /// `"<uuid>-pokemon-uranium"` -> `"pokemon uranium"`. Nil when
    /// the legacy name has no slug part.
    private static func legacySlugTitle(fromFolderName folderName: String) -> String? {
        guard folderName.count > 37 else { return nil }
        let slug = String(folderName.dropFirst(37))
        let words = slug.split(separator: "-").filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Move the per-game UserDefaults families over to the new id.
    /// An existing value under the new id wins (it can only exist
    /// if a same-named game already migrated, in which case the
    /// newer state is already the user's active one).
    private static func migrateUserDefaultsKeys(fromID oldID: String, toID newID: String) {
        let defaults = UserDefaults.standard
        let keyPairs = [
            (DefaultsKey.controlsLayout(gameID: oldID), DefaultsKey.controlsLayout(gameID: newID)),
            (DefaultsKey.controllerMap(gameID: oldID), DefaultsKey.controllerMap(gameID: newID)),
        ]
        for (oldKey, newKey) in keyPairs {
            guard let value = defaults.data(forKey: oldKey) else { continue }
            if defaults.data(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }
    }
}
