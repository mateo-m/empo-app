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
/// save files or re-import. The one-time library alert
/// (`DuplicateGamesNotice`) explains the move and lists each copy.
/// The which-copy-wins policy itself lives in GameProbe's
/// `ContainerMigrationPlanner` so the Linux CI tests exercise it.
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

    /// App-side context for a planner candidate, keyed by the
    /// candidate id (the legacy folder name).
    private struct CandidateContext {
        let url: URL
        let legacyID: String
        /// What the user calls this copy: their custom title when
        /// set, else the game's title. The duplicate notice lists
        /// this.
        let displayTitle: String
    }

    static func migrateLegacyContainers(fm: FileManager = .default) {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: GameContainer.rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        var takenNames = Set<String>()
        var contexts: [String: CandidateContext] = [:]
        var candidates: [ContainerMigrationPlanner.Candidate] = []

        for url in entries {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            guard isDirectory else { continue }

            let folderName = url.lastPathComponent
            guard let legacyID = GameContainer.legacyUUIDPrefix(folderName: folderName) else {
                takenNames.insert(folderName.lowercased())
                continue
            }

            let metadata = GameMetadata.load(from: GameContainer(url: url))
            let title = migrationTitle(forLegacyContainerAt: url, metadata: metadata)
            contexts[folderName] = CandidateContext(
                url: url,
                legacyID: legacyID,
                displayTitle: metadata.customTitle ?? title
            )
            candidates.append(
                ContainerMigrationPlanner.Candidate(
                    id: folderName,
                    preferredName: GameFolderName.sanitize(title),
                    lastPlayed: metadata.lastPlayed,
                    dateAdded: metadata.dateAdded
                ))
        }

        let groups = ContainerMigrationPlanner.plan(
            candidates: candidates,
            takenLowercasedNames: takenNames
        )
        for group in groups {
            var titleClaimed = group.titleAlreadyTaken
            for candidate in group.candidates {
                guard let context = contexts[candidate.id] else { continue }

                if titleClaimed {
                    quarantineDuplicate(context, preferredName: candidate.preferredName, fm: fm)
                    continue
                }

                let destination = GameContainer.rootURL
                    .appendingPathComponent(candidate.preferredName, isDirectory: true)
                do {
                    try fm.moveItem(at: context.url, to: destination)
                } catch {
                    // Leave the tree under its legacy name; the next
                    // launch retries. Discovery still surfaces it
                    // (any directory is a container), so the game
                    // stays playable meanwhile. The title stays
                    // unclaimed so the next-best duplicate can take
                    // it rather than getting quarantined behind a
                    // rename that never happened.
                    NSLog(
                        "[GameContainerMigration] Failed to rename %@ -> %@: %@",
                        candidate.id,
                        candidate.preferredName,
                        error.localizedDescription)
                    continue
                }

                titleClaimed = true
                migrateUserDefaultsKeys(fromID: context.legacyID, toID: candidate.preferredName)
                NSLog(
                    "[GameContainerMigration] Renamed %@ -> %@",
                    candidate.id,
                    candidate.preferredName)
            }
        }
    }

    /// Move a duplicate legacy import - whole, saves included - out
    /// of the library into `Duplicate Games/`. Nothing is merged or
    /// deleted; the user resolves duplicates manually in Files. The
    /// move is recorded so the library can show the one-time
    /// explanatory alert (`pendingDuplicateNoticeNames`).
    private static func quarantineDuplicate(
        _ context: CandidateContext,
        preferredName: String,
        fm: FileManager
    ) {
        try? fm.createDirectory(at: duplicatesRootURL, withIntermediateDirectories: true)
        excludeFromBackup(duplicatesRootURL)

        let name = GameFolderName.uniqueName(preferring: preferredName) { proposed in
            fm.fileExists(atPath: duplicatesRootURL.appendingPathComponent(proposed).path)
        }
        let destination = duplicatesRootURL.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.moveItem(at: context.url, to: destination)
            recordQuarantine(displayTitle: context.displayTitle, folderName: name)
            NSLog(
                "[GameContainerMigration] Moved duplicate %@ -> Duplicate Games/%@",
                context.url.lastPathComponent,
                name)
        } catch {
            NSLog(
                "[GameContainerMigration] Failed to quarantine duplicate %@: %@",
                context.url.lastPathComponent,
                error.localizedDescription)
        }
    }

    // MARK: - Duplicate notice

    /// Display entries for `Duplicate Games/` moves the user hasn't
    /// been told about yet: the user's custom title (or the game's
    /// title), with the destination folder name appended when it
    /// differs so the copy is findable in Files. Persisted in
    /// UserDefaults so a force-quit before the library appears
    /// doesn't swallow the notice.
    static func pendingDuplicateNoticeNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: DefaultsKey.pendingDuplicateGameNames) ?? []
    }

    /// The user has seen the alert.
    static func clearPendingDuplicateNotice() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingDuplicateGameNames)
    }

    private static func recordQuarantine(displayTitle: String, folderName: String) {
        let entry =
            displayTitle.caseInsensitiveCompare(folderName) == .orderedSame
            ? folderName
            : "\(displayTitle) (\(folderName))"
        var names = pendingDuplicateNoticeNames()
        names.append(entry)
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
    private static func migrationTitle(
        forLegacyContainerAt url: URL,
        metadata: GameMetadata
    ) -> String {
        let container = GameContainer(url: url)

        if let iniTitle = GameINI.parseINIValue(
            at: container.gameURL, section: "game", key: "title")
        {
            return iniTitle
        }
        if let baseTitle = metadata.baseTitle {
            return baseTitle
        }
        return ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: url.lastPathComponent)
            ?? GameFolderName.fallback
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
