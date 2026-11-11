// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// Renames pre-v0.5 `<uuid>-<slug>` folders to the game's title. It
/// also renames folders from the mojibake decode era, when
/// Windows-1252 INI titles read as Shift-JIS (`Pok駑on Empyrean/`).
///
/// A folder name must be exactly the game's INI title. Some games
/// derive their data locations from that title, so a copy named
/// `Testing 2` reads the data of "Testing". When several legacy
/// imports resolve to one title, one copy keeps the name. The other
/// copies move whole into `Documents/Duplicate Games/`.
///
/// The container id is the folder name, so the per-game
/// UserDefaults keys must move with the rename.
///
/// Run this before anything calls `GameContainer.discover()`.
enum GameContainerMigration {

    /// Outside `Games/`, so discovery skips these copies. Not hidden,
    /// so the user can open them in the Files app.
    static let duplicatesRootURL: URL = DataDirectory.documentsRootURL
        .appendingPathComponent("Duplicate Games", isDirectory: true)

    @MainActor private static var didRunThisLaunch = false

    @MainActor
    static func migrateLegacyContainersIfNeeded() {
        guard !didRunThisLaunch else { return }
        didRunThisLaunch = true
        migrateLegacyContainers()
    }

    private struct CandidateContext {
        let url: URL
        let legacyID: String
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

            // For a title-based folder, the full folder name is the
            // container id, so it is also the legacy id. Mojibake
            // always has scalars far above Latin, so this check skips
            // the INI read for ASCII names.
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
                    // No code reads data paths through
                    // `Duplicate Games/`, and a re-import reads the
                    // title from the INI. So the user's custom title
                    // can name the folder.
                    quarantineDuplicate(
                        context,
                        preferredName: GameFolderName.sanitize(context.displayTitle),
                        fm: fm)
                    continue
                }

                let destination = GameContainer.rootURL
                    .appendingPathComponent(candidate.preferredName, isDirectory: true)
                // Copy the keys BEFORE the rename. A crash between the
                // two steps then leaves both key sets, which is
                // harmless. In the reverse order, the old keys stay
                // forever: a renamed folder no longer parses as
                // legacy, so this code never sees it again.
                let copiedKeys = copyUserDefaultsKeys(
                    fromID: context.legacyID, toID: candidate.preferredName)
                // Use the same order for the profile-migration record.
                // A stranded entry makes the profile migration treat
                // the renamed game as new and create a duplicate
                // profile.
                let copiedRecordEntry = copyProfileMigrationRecordEntry(
                    fromID: candidate.id, toID: candidate.preferredName)
                do {
                    try fm.moveItem(at: context.url, to: destination)
                } catch {
                    // The folder keeps its legacy name until the next
                    // launch. The title stays free for the next
                    // duplicate, so roll back the copied keys now.
                    // Otherwise they block the key copy of that
                    // duplicate and give it the controls of this copy.
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
                // `resolve` renames a mojibake-era data directory. If
                // it fails, the resolve at game launch tries again.
                let moved = GameContainer(url: destination)
                _ = DataDirectory.resolve(
                    for: moved, core: GameCores.core(forGameAt: moved.gameURL))
                NSLog(
                    "[GameContainerMigration] Renamed %@ -> %@",
                    candidate.id,
                    candidate.preferredName)
            }
        }
    }

    private static func quarantineDuplicate(
        _ context: CandidateContext,
        preferredName: String,
        fm: FileManager
    ) {
        // Do not exclude this folder from backup. A quarantined copy
        // never launches, so it can hold the only copy of its saves.
        try? fm.createDirectory(at: duplicatesRootURL, withIntermediateDirectories: true)

        // Case-variant names collide when the user copies
        // `Duplicate Games/` to a case-insensitive volume.
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

    static func pendingDuplicateNoticeNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: DefaultsKey.pendingDuplicateGameNames) ?? []
    }

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

    /// A value under the new id wins: it belongs to a same-named game
    /// that migrated before.
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

    #if os(iOS)
    private static var profileMigrationRecordURL: URL {
        LayoutProfilesManager.profilesRootURL
            .appendingPathComponent(MigrationRecord.fileName)
    }

    private static func copyProfileMigrationRecordEntry(
        fromID oldID: String, toID newID: String
    ) -> Bool {
        let url = profileMigrationRecordURL
        guard var record = MigrationRecord.load(at: url),
            let entry = record.games[oldID], record.games[newID] == nil
        else { return false }
        record.games[newID] = entry
        return saveProfileMigrationRecord(record, to: url)
    }

    private static func removeProfileMigrationRecordEntry(forID id: String) {
        let url = profileMigrationRecordURL
        guard var record = MigrationRecord.load(at: url),
            record.games.removeValue(forKey: id) != nil
        else { return }
        saveProfileMigrationRecord(record, to: url)
    }

    @discardableResult
    private static func saveProfileMigrationRecord(_ record: MigrationRecord, to url: URL) -> Bool {
        do {
            try record.save(to: url)
            return true
        } catch {
            NSLog(
                "[GameContainerMigration] Failed to save %@: %@",
                url.lastPathComponent, error.localizedDescription)
            return false
        }
    }
    #else
    // The Mac app has no layout profiles, so it has no record to update.
    private static func copyProfileMigrationRecordEntry(fromID oldID: String, toID newID: String) -> Bool {
        false
    }

    private static func removeProfileMigrationRecordEntry(forID id: String) {}
    #endif
}
