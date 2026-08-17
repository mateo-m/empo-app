import Foundation
import GameProbe

/// Launch-time migration from the pre-v0.5 `<uuid>-<slug>` container
/// directories to title-based directories (`Games/Pokémon Uranium/`
/// instead of `Games/3F2504E0-...-pokemon-uranium/`).
///
/// The same pass renames title-based folders from the mojibake
/// decode era, when Windows-1252 INI titles read as Shift-JIS and
/// named containers like `Pok駑on Empyrean/`. Those folders rename
/// to the corrected title only when the current name is exactly the
/// old decoder's rendering of it (`ContainerMigrationPlanner
/// .mojibakeRenameTarget`), through the same planner, quarantine
/// policy, and defaults-key transfer as the uuid migration. A
/// successful rename also re-keys the game's profile-migration
/// record entry and heals its shared data directory right away.
/// `DataDirectory.resolve` repeats the heal at game launch for
/// anything this pass could not fix.
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
/// and moves with the rename at no extra cost.
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
            if let legacyID = GameContainer.legacyUUIDPrefix(folderName: folderName) {
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
                continue
            }

            // Title-based folders from the mojibake decode era
            // (`Pok駑on Empyrean/`) rename to the corrected title
            // through the same planner. Their per-game defaults are
            // keyed by the FULL folder name - that is the container
            // id for title-based names - so it doubles as the
            // legacy id here. The scalar check skips the INI read
            // for the ASCII-named bulk of the library. Mojibake
            // always contains scalars far above Latin.
            if folderName.unicodeScalars.contains(where: { $0.value >= 0x0370 }) {
                let metadata = GameMetadata.load(from: GameContainer(url: url))
                let title = migrationTitle(forLegacyContainerAt: url, metadata: metadata)
                if let target = ContainerMigrationPlanner.mojibakeRenameTarget(
                    folderName: folderName, title: title)
                {
                    contexts[folderName] = CandidateContext(
                        url: url,
                        legacyID: folderName,
                        displayTitle: metadata.customTitle ?? title
                    )
                    candidates.append(
                        ContainerMigrationPlanner.Candidate(
                            id: folderName,
                            preferredName: target,
                            lastPlayed: metadata.lastPlayed,
                            dateAdded: metadata.dateAdded
                        ))
                    continue
                }
            }

            takenNames.insert(folderName.lowercased())
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
                    // Quarantine folders are named for HUMANS, not
                    // for games: nothing resolves data paths
                    // through `Duplicate Games/`, and a later
                    // re-import derives identity from the INI, not
                    // the folder. So the user's custom title, when
                    // set, beats the INI title - "Rejuv kirin
                    // updated" identifies a copy in Files far
                    // better than "Pokemon Rejuvenation 2".
                    quarantineDuplicate(
                        context,
                        preferredName: GameFolderName.sanitize(context.displayTitle),
                        fm: fm)
                    continue
                }

                let destination = GameContainer.rootURL
                    .appendingPathComponent(candidate.preferredName, isDirectory: true)
                // Copy the per-game UserDefaults families BEFORE the
                // rename: a crash between the two steps then leaves
                // both key families present (harmless - the copy is
                // idempotent and never overwrites), whereas the
                // reverse order would orphan the old keys forever,
                // because a renamed folder no longer parses as
                // legacy and this code never sees it again.
                let copiedKeys = copyUserDefaultsKeys(
                    fromID: context.legacyID, toID: candidate.preferredName)
                // The profile-migration record maps container ids
                // to migrated-layout hashes. Same order and same
                // reasoning as the defaults keys: copy the entry to
                // the new id first, drop the old id after the
                // rename lands. A stranded entry would make the
                // controls-to-profile migration treat the renamed
                // game as never migrated and mint a duplicate
                // profile.
                let copiedRecordEntry = copyProfileMigrationRecordEntry(
                    fromID: candidate.id, toID: candidate.preferredName)
                do {
                    try fm.moveItem(at: context.url, to: destination)
                } catch {
                    // Leave the tree under its legacy name. The next
                    // launch retries. Discovery still surfaces it
                    // (any directory is a container), so the game
                    // stays playable meanwhile - including its
                    // controls, since the legacy keys are still in
                    // place. The title stays unclaimed so the
                    // next-best duplicate can take it rather than
                    // getting quarantined behind a rename that
                    // never happened - which is exactly why the
                    // keys copied above must roll back NOW: left
                    // in place, they would block that duplicate's
                    // own key copy (new-id-wins) and donate this
                    // copy's controls to a different game.
                    for key in copiedKeys {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    if copiedRecordEntry {
                        removeProfileMigrationRecordEntry(forID: candidate.preferredName)
                    }
                    NSLog(
                        "[GameContainerMigration] Failed to rename %@ -> %@: %@",
                        candidate.id,
                        candidate.preferredName,
                        error.localizedDescription)
                    continue
                }

                titleClaimed = true
                removeUserDefaultsKeys(forID: context.legacyID)
                removeProfileMigrationRecordEntry(forID: candidate.id)
                // Heal the game's shared data directory now instead
                // of waiting for its next launch: `resolve` renames
                // a mojibake-era directory as it walks. Failure is
                // fine - the resolve at game launch retries, and
                // the alias matcher keeps the old name reachable
                // meanwhile.
                _ = DataDirectory.resolve(for: GameContainer(url: destination))
                NSLog(
                    "[GameContainerMigration] Renamed %@ -> %@",
                    candidate.id,
                    candidate.preferredName)
            }
        }
    }

    /// Move a duplicate legacy import - whole, saves included - out
    /// of the library into `Duplicate Games/`. Nothing is merged or
    /// deleted. The user resolves duplicates manually in Files. The
    /// move is recorded so the library can show the one-time
    /// explanatory alert (`pendingDuplicateNoticeNames`).
    private static func quarantineDuplicate(
        _ context: CandidateContext,
        preferredName: String,
        fm: FileManager
    ) {
        // Deliberately NOT excluded from backup, unlike `Games/`:
        // a quarantined copy can hold the user's only copy of its
        // saves (it never launches, so the launch drain never
        // reaches it), and the alert promised the copies were
        // preserved. Small price in quota. Irreplaceable data.
        try? fm.createDirectory(at: duplicatesRootURL, withIntermediateDirectories: true)

        // Case-insensitive collision check, per `uniqueName`'s
        // contract: case-variant duplicates would collide when the
        // user copies `Duplicate Games/` to a case-insensitive
        // volume.
        let existingLowercased = Set(
            ((try? fm.contentsOfDirectory(atPath: duplicatesRootURL.path)) ?? [])
                .map { $0.lowercased() }
        )
        let name = GameFolderName.uniqueName(preferring: preferredName) { proposed in
            existingLowercased.contains(proposed.lowercased())
        }
        let destination = duplicatesRootURL.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.moveItem(at: context.url, to: destination)
            recordQuarantine(displayTitle: context.displayTitle, folderName: name)
            // The quarantined copy's per-game UserDefaults would
            // never be read again (its id left the library), so
            // they go now instead of leaking forever. A later
            // re-import of the copy gets the canonical title and
            // the canonical keys. Its profile-migration record
            // entry is dead weight for the same reason.
            removeUserDefaultsKeys(forID: context.legacyID)
            removeProfileMigrationRecordEntry(forID: context.url.lastPathComponent)
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

    /// Title for a legacy container, in the same priority the
    /// import pipeline now uses for naming: the INI title, then the
    /// import-time base title (JGP manifest name), then the old
    /// folder slug as a last resort.
    private static func migrationTitle(
        forLegacyContainerAt url: URL,
        metadata: GameMetadata
    ) -> String {
        let container = GameContainer(url: url)

        if let iniTitle = GameINI.gameTitle(at: container.gameURL) {
            return iniTitle
        }
        if let baseTitle = metadata.baseTitle {
            return baseTitle
        }
        return ContainerMigrationPlanner.slugTitle(fromLegacyFolderName: url.lastPathComponent)
            ?? GameFolderName.fallback
    }

    /// Copy the per-game UserDefaults families to the new id,
    /// returning the keys this call WROTE (so a failed
    /// rename can roll exactly those back). An existing value
    /// under the new id wins - it belongs to a same-named game
    /// that already migrated. The old keys stay until
    /// `removeUserDefaultsKeys` runs after the rename lands, so a
    /// game still under its legacy name keeps its controls.
    @discardableResult
    private static func copyUserDefaultsKeys(
        fromID oldID: String, toID newID: String
    )
        -> [String]
    {
        let defaults = UserDefaults.standard
        let keyPairs = [
            (DefaultsKey.controlsLayout(gameID: oldID), DefaultsKey.controlsLayout(gameID: newID)),
            (DefaultsKey.controllerMap(gameID: oldID), DefaultsKey.controllerMap(gameID: newID)),
        ]
        var written: [String] = []
        for (oldKey, newKey) in keyPairs {
            guard let value = defaults.data(forKey: oldKey) else { continue }
            if defaults.data(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
                written.append(newKey)
            }
        }
        return written
    }

    private static func removeUserDefaultsKeys(forID id: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.controlsLayout(gameID: id))
        defaults.removeObject(forKey: DefaultsKey.controllerMap(gameID: id))
    }

    // MARK: - Profile migration record

    /// `Documents/Profiles/.migration.json` maps container ids to
    /// the layout content already migrated into profiles
    /// (`ProfileMigration.decide` consults it). Entries must follow
    /// a container rename or the migration re-runs under the new
    /// id. The pin itself lives inside the container
    /// (`EmpoState/`), so it travels with the rename on its own.
    private static var profileMigrationRecordURL: URL {
        LayoutProfilesManager.profilesRootURL
            .appendingPathComponent(MigrationRecord.fileName)
    }

    /// Copy the record entry to the new id, returning whether this
    /// call wrote one (so a failed rename can roll exactly that
    /// back). An existing entry under the new id wins, mirroring
    /// `copyUserDefaultsKeys`.
    private static func copyProfileMigrationRecordEntry(
        fromID oldID: String, toID newID: String
    ) -> Bool {
        let url = profileMigrationRecordURL
        var record = MigrationRecord.load(at: url)
        guard let entry = record.games[oldID], record.games[newID] == nil else {
            return false
        }
        record.games[newID] = entry
        record.save(to: url)
        return true
    }

    private static func removeProfileMigrationRecordEntry(forID id: String) {
        let url = profileMigrationRecordURL
        var record = MigrationRecord.load(at: url)
        guard record.games.removeValue(forKey: id) != nil else { return }
        record.save(to: url)
    }
}
