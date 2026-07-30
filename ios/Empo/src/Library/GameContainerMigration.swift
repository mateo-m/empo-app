import Foundation
import GameProbe

/// Launch-time migration from the pre-v0.5 `<uuid>-<slug>` container
/// directories to title-based directories (`Games/Pokémon Uranium/`
/// instead of `Games/3F2504E0-...-pokemon-uranium/`).
///
/// Renaming the directory also changes the container id (the id IS
/// the folder name now), so the per-game UserDefaults key families
/// (`controlsLayout.<id>`, `controllerMap.<id>`) move with it. All
/// other per-game state (saves, settings, metadata, logs, controls
/// manifest) lives inside the container and travels with the rename
/// for free.
///
/// Must run before anything enumerates `GameContainer.discover()`
/// (library scan, save migration, crash tracker), so both singleton
/// entry points (`GameLibrary.init`, `AppState.init`) call
/// `migrateLegacyContainersIfNeeded()` first. Idempotent: once no
/// legacy names remain the scan is a cheap directory listing.
enum GameContainerMigration {

    @MainActor private static var didRunThisLaunch = false

    @MainActor
    static func migrateLegacyContainersIfNeeded() {
        guard !didRunThisLaunch else { return }
        didRunThisLaunch = true
        migrateLegacyContainers()
    }

    static func migrateLegacyContainers(fm: FileManager = .default) {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: GameContainer.rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        // Names already in use, compared case-insensitively so two
        // titles differing only in case can't produce directories
        // that collide on a case-insensitive filesystem.
        var takenNames = Set<String>()
        var legacyContainers: [(url: URL, legacyID: String)] = []

        for url in entries {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            guard isDirectory else { continue }

            let name = url.lastPathComponent
            if let uuid = GameContainer.legacyUUIDPrefix(folderName: name) {
                legacyContainers.append((url, uuid))
            } else {
                takenNames.insert(name.lowercased())
            }
        }

        for (url, legacyID) in legacyContainers {
            let preferred = GameFolderName.sanitize(migrationTitle(forLegacyContainerAt: url))
            let newName = GameFolderName.uniqueName(preferring: preferred) {
                takenNames.contains($0.lowercased())
            }
            let destination = GameContainer.rootURL
                .appendingPathComponent(newName, isDirectory: true)

            do {
                try fm.moveItem(at: url, to: destination)
            } catch {
                // Leave the tree under its legacy name; the next
                // launch retries. Discovery still surfaces it (any
                // directory is a container), so the game stays
                // playable meanwhile.
                NSLog(
                    "[GameContainerMigration] Failed to rename %@ -> %@: %@",
                    url.lastPathComponent,
                    newName,
                    error.localizedDescription)
                continue
            }

            takenNames.insert(newName.lowercased())
            migrateUserDefaultsKeys(fromID: legacyID, toID: newName)
            NSLog(
                "[GameContainerMigration] Renamed %@ -> %@",
                url.lastPathComponent,
                newName)
        }
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
