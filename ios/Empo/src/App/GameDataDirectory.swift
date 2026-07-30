import Foundation
import GameProbe

/// Resolves the writable data directory a session hands the engine
/// (`MKXPSessionConfig.userDataDirectory`, surfaced to games as
/// `System.data_directory`).
///
/// Default: the per-game `<container>/UserData/` directory.
///
/// When the game's effective mkxp config (`Game/mkxp.json` merged
/// with the `EmpoState/mkxp.json` overlay) declares `dataPathOrg`
/// and/or `dataPathApp`, the data directory instead lives at
///
///     Documents/GameData/<org>/<app>/
///
/// shared across containers and visible in the Files app next to
/// `Games/`. That mirrors desktop mkxp-z, where the two keys feed
/// `SDL_GetPrefPath(org, app)`: any two game releases declaring the
/// same pair see the same data directory. Fan games rely on this to
/// carry saves across versions - which matters more now that
/// re-importing a new version replaces the old container.
///
/// Defaults mirror mkxp-z's: an org of `"."` (or blank) contributes
/// no path component, and a missing `dataPathApp` falls back to the
/// game's INI title, then to `"mkxp-z"` - the same rule
/// `SaveMigration.legacyDataPathDefaults` documents for the old
/// engine builds.
///
/// `GameData/` is intentionally NOT excluded from backups (unlike
/// `Games/`): it holds the data games choose to persist - saves,
/// settings, mod state - which is small and precious.
enum GameDataDirectory {

    /// Parent of all shared data directories. `Documents/GameData/`.
    static let sharedRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GameData", isDirectory: true)

    /// Pure resolution; no filesystem writes.
    static func resolve(for container: GameContainer) -> URL {
        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: container.empoStateURL,
            gameDirectory: container.gameURL
        )
        guard dataPath.isDeclared else { return container.userDataURL }

        var url = sharedRootURL
        if let org = folderComponent(dataPath.org) {
            url.appendPathComponent(org, isDirectory: true)
        }
        let app =
            folderComponent(dataPath.app)
            ?? folderComponent(
                GameINI.parseINIValue(
                    at: container.gameURL, section: "game", key: "title"))
            ?? "mkxp-z"
        return url.appendingPathComponent(app, isDirectory: true)
    }

    /// Resolve and make the directory exist. On the first launch
    /// after a game starts declaring `dataPathOrg`/`dataPathApp`
    /// (shared directory not on disk yet), the contents of the
    /// game's `UserData/` move over so saves written before the
    /// redirect carry forward. An already-populated shared
    /// directory is left alone - it may belong to another installed
    /// release of the same game.
    static func resolveAndPrepare(for container: GameContainer) -> URL {
        let resolved = resolve(for: container)
        if resolved.path == container.userDataURL.path {
            return container.ensureUserDataDirectory()
        }

        let fm = FileManager.default
        let firstUse = !fm.fileExists(atPath: resolved.path)
        try? fm.createDirectory(at: resolved, withIntermediateDirectories: true)
        if firstUse {
            adoptUserDataContents(of: container, into: resolved, fm: fm)
        }
        return resolved
    }

    /// A declared org/app value as a single safe path component.
    /// `"."` or blank means "contributes nothing" (mkxp-z treats a
    /// `"."` org as the no-org default).
    private static func folderComponent(_ raw: String?) -> String? {
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed != "."
        else { return nil }
        return GameFolderName.sanitize(trimmed)
    }

    private static func adoptUserDataContents(
        of container: GameContainer,
        into destination: URL,
        fm: FileManager
    ) {
        let userDataDir = container.userDataURL
        guard let entryNames = try? fm.contentsOfDirectory(atPath: userDataDir.path),
            !entryNames.isEmpty
        else { return }

        for name in entryNames {
            let source = userDataDir.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            do {
                try fm.moveItem(at: source, to: target)
            } catch {
                NSLog(
                    "[GameDataDirectory] Failed to move %@ -> %@: %@",
                    source.path,
                    target.path,
                    error.localizedDescription)
            }
        }
        NSLog(
            "[GameDataDirectory] Adopted UserData contents of %@ into %@",
            container.folderName,
            destination.path)
    }
}
