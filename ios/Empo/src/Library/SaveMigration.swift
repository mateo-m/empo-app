import Foundation
import GameProbe

/// Startup funnel for saves written by old Empo builds. Two legacy
/// sources feed the per-game `UserData/` staging directory:
///
///   - The Application Support directory old engine builds derived
///     via `SDL_GetPrefPath` (`LegacyDataPathDefaults`).
///   - Concatenated `UserDataGame.rxdata` files at the container
///     root, from the v0.2.1 trailing-slash regression
///     (`ConcatenatedSaveRecovery`).
///
/// `DataDirectory.resolveAndPrepare` drains `UserData/` into the
/// shared `Documents/Data/` tree at launch and removes it, so this
/// funnel creates the directory lazily - only when it has a legacy
/// save to move - to keep the drain/recreate cycle quiet.
enum SaveMigration {

    static func migrateLegacySavesIfNeeded(for container: GameContainer) {
        let fm = FileManager.default
        let userDataDir = container.userDataURL
        recoverConcatenatedSaves(for: container, userDataDir: userDataDir, fm: fm)

        let legacyDir = legacySaveDirectory(for: container)

        guard legacyDir.path != userDataDir.path else { return }
        guard fm.fileExists(atPath: legacyDir.path) else { return }
        guard let entryNames = try? fm.contentsOfDirectory(atPath: legacyDir.path) else { return }

        if !entryNames.isEmpty {
            try? fm.createDirectory(at: userDataDir, withIntermediateDirectories: true)
        }
        for name in entryNames {
            let entry = legacyDir.appendingPathComponent(name, isDirectory: false)
            let destination = UniqueFileName.firstAvailableURL(
                in: userDataDir, preferring: name, fm: fm)
            do {
                try fm.moveItem(at: entry, to: destination)
            } catch {
                NSLog(
                    "[SaveMigration] Failed to move %@ -> %@: %@",
                    entry.path,
                    destination.path,
                    error.localizedDescription)
            }
        }

        if let leftovers = try? fm.contentsOfDirectory(atPath: legacyDir.path) {
            if leftovers.isEmpty {
                try? fm.removeItem(at: legacyDir)
            } else {
                NSLog(
                    "[SaveMigration] Legacy Application Support directory still contains %ld entr%@ for %@: %@",
                    leftovers.count,
                    leftovers.count == 1 ? "y" : "ies",
                    container.folderName,
                    leftovers.joined(separator: ", "))
            }
        }
    }

    static func migrateAllDiscoveredGamesIfNeeded() {
        for container in GameContainer.discover() {
            migrateLegacySavesIfNeeded(for: container)
        }
    }

    /// Recover saves written at the container root when
    /// `System.data_directory` lacked a trailing slash and a game
    /// concatenated `dir + filename` (e.g. `UserDataGame.rxdata`).
    /// Naming and merge policy live in `ConcatenatedSaveRecovery`
    /// (GameProbe) where the Linux CI tests pin them.
    private static func recoverConcatenatedSaves(
        for container: GameContainer, userDataDir: URL, fm: FileManager
    ) {
        let root = container.url
        guard let entryNames = try? fm.contentsOfDirectory(atPath: root.path) else { return }

        for name in entryNames {
            guard let remainder = ConcatenatedSaveRecovery.remainder(ofConcatenatedName: name)
            else { continue }
            let source = root.appendingPathComponent(name, isDirectory: false)
            guard isRegularFile(source, fm: fm) else { continue }

            let canonical = userDataDir.appendingPathComponent(remainder, isDirectory: false)
            do {
                try fm.createDirectory(at: userDataDir, withIntermediateDirectories: true)
                try ConcatenatedSaveRecovery.merge(source: source, canonical: canonical, fm: fm)
                NSLog(
                    "[SaveMigration] Recovered concatenated save %@ for %@",
                    name,
                    container.folderName)
            } catch {
                NSLog(
                    "[SaveMigration] Failed to recover concatenated save %@ -> %@: %@",
                    source.path,
                    canonical.path,
                    error.localizedDescription)
            }
        }
    }

    private static func isRegularFile(_ url: URL, fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Where the OLD engine builds kept this game's data directory:
    /// `Application Support/<org>/<app>/`, with the raw (never
    /// sanitized) pair the legacy engine fed to `SDL_GetPrefPath`.
    /// Reads `Game/mkxp.json` only - the per-game overlay did not
    /// exist in the era this migrates from.
    private static func legacySaveDirectory(for container: GameContainer) -> URL {
        let gameDir = container.gameURL

        var declaredOrg: String?
        var declaredApp: String?
        if let json = try? Data(contentsOf: gameDir.appendingPathComponent("mkxp.json")),
            let raw = json.decodeAsLooseText(),
            let object = JSON5LiteParser.parseObject(raw)
        {
            declaredOrg = object["dataPathOrg"] as? String
            declaredApp = object["dataPathApp"] as? String
        }

        let defaults = LegacyDataPathDefaults.resolve(
            declaredOrg: declaredOrg,
            declaredApp: declaredApp,
            iniTitle: GameINI.parseINIValue(at: gameDir, section: "game", key: "title")
        )
        return applicationSupportDirectory()
            .appendingPathComponent(defaults.org, isDirectory: true)
            .appendingPathComponent(defaults.app, isDirectory: true)
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
