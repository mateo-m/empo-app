import Foundation
import GameProbe
import Synchronization

/// Resolves the writable data directory a session hands the engine
/// (`MKXPSessionConfig.userDataDirectory`, surfaced to games as
/// `System.data_directory`).
///
/// Every game resolves to
///
///     Documents/Data/<org>/<app>/
///
/// shared across containers and visible in the Files app next to
/// `Games/`. That mirrors desktop mkxp-z, where `dataPathOrg` and
/// `dataPathApp` from the game's effective mkxp config
/// (`Game/mkxp.json` merged with the `EmpoState/mkxp.json` overlay)
/// feed `SDL_GetPrefPath(org, app)` for every game: any two game
/// releases that resolve to the same pair see the same data
/// directory. Fan games rely on this to carry saves across
/// versions - which matters more now that re-importing a new
/// version replaces the old container.
///
/// Defaults mirror mkxp-z's: an org of `"."` (or blank) contributes
/// no path component, and a missing `dataPathApp` falls back to the
/// game's INI title, then to the container folder name (see
/// `MkxpDataPath.sharedDirectoryComponents` for why the engine's
/// own `"mkxp-z"` last resort is not used here). Existing children
/// of `Data/` are reused case-insensitively so a case-only title
/// change between releases keeps its saves, the way desktop
/// Windows would.
///
/// The per-game `<container>/UserData/` directory is now a legacy
/// staging area only: `SaveMigration` funnels old save locations
/// into it at startup, and `resolveAndPrepare` drains it into the
/// shared directory at launch (`LegacyDataDrain` - recursive
/// merge, newer file wins, nothing deleted).
///
/// `Data/` is intentionally NOT excluded from backups (unlike
/// `Games/`): it holds the data games choose to persist - saves,
/// settings, mod state - which is small and precious.
enum DataDirectory {

    /// Parent of all shared data directories. `Documents/Data/`.
    static let sharedRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Data", isDirectory: true)

    /// Serializes every drain in the process. Two detached deletes
    /// (bulk delete) or a delete racing a launch could otherwise
    /// interleave their move-with-rename steps on one shared
    /// directory and fail spuriously.
    private static let drainLock = Mutex<Void>(())

    /// The component derivation (org/app normalization, INI-title
    /// fallback) lives on `MkxpDataPath.sharedDirectoryComponents`
    /// in GameProbe so the Linux CI tests exercise it. This wrapper
    /// adds the on-disk part: case-insensitive reuse of existing
    /// directories.
    static func resolve(for container: GameContainer) -> URL {
        let dataPath = ManagedMkxpConfig.readDataPath(
            stateDirectory: container.empoStateURL,
            gameDirectory: container.gameURL
        )
        let iniTitle = GameINI.parseINIValue(
            at: container.gameURL, section: "game", key: "title")
        let components = dataPath.sharedDirectoryComponents(
            iniTitleFallback: iniTitle,
            folderNameFallback: container.folderName
        )

        let fm = FileManager.default
        var url = sharedRootURL
        for component in components {
            // Directories only: the matcher exists to REUSE an
            // existing directory across case-variant titles. A
            // case-variant FILE must not hijack the match - on
            // case-sensitive APFS the exact-case directory can
            // coexist with it and gets created normally.
            let existingDirectories =
                ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { name in
                    var isDirectory: ObjCBool = false
                    return fm.fileExists(
                        atPath: url.appendingPathComponent(name).path,
                        isDirectory: &isDirectory) && isDirectory.boolValue
                }
            let chosen = DirectoryNameMatch.preferringExisting(
                component, among: existingDirectories)
            url.appendPathComponent(chosen, isDirectory: true)
        }
        return url
    }

    /// Resolve, make the directory exist, and drain the legacy
    /// `UserData/` directory into it so saves written before the
    /// redirect carry forward. The drain runs at every launch, not
    /// only the first: `SaveMigration` can funnel newly discovered
    /// legacy saves into `UserData/` at any later startup, and a
    /// partial drain resumes next time.
    ///
    /// When the shared directory cannot exist (a user-created FILE
    /// named `Data`, or one squatting on a component), the session
    /// falls back to the per-game `UserData/` directory rather
    /// than handing the engine an uncreatable path - which would
    /// silently break every in-game save.
    static func resolveAndPrepare(for container: GameContainer) -> URL {
        let resolved = resolve(for: container)
        let fm = FileManager.default
        try? fm.createDirectory(at: resolved, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            NSLog(
                "[DataDirectory] Cannot create %@; falling back to per-game UserData",
                resolved.path)
            let staging = container.userDataURL
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        }

        let outcome = drainLock.withLock { _ in
            LegacyDataDrain.drain(from: container.userDataURL, into: resolved, fm: fm)
        }
        logDrain(outcome, container: container, destination: resolved)
        return resolved
    }

    /// Rescue path for game deletion. Two save locations sit
    /// inside the doomed container tree:
    ///
    ///   - `UserData/`, for a pre-0.5 container that never
    ///     launched under the shared-data scheme.
    ///   - "Portable mode" saves games keep NEXT TO their game
    ///     files (`Game/Game.rxdata`, a `Save Data/` folder - see
    ///     `PortableGameSaves`). Only the deletion rescue may move
    ///     these: an installed game needs them exactly where they
    ///     are.
    ///
    /// Both funnel through `UserData/` and drain into the shared
    /// directory. Does nothing - and creates nothing - when there
    /// is nothing to rescue.
    ///
    /// Returns false when anything failed to move, including when
    /// the shared directory itself cannot exist (then the fallback
    /// above IS `UserData/`, and draining a directory into itself
    /// proves nothing). The caller must NOT delete the container
    /// in that case: the delete alert promises the saves survive.
    static func rescueUserDataBeforeDeletion(of container: GameContainer) -> Bool {
        let fm = FileManager.default

        // What still needs rescuing is judged from disk, not from
        // what any step claims: a save whose move FAILED must
        // count as unrescued, not as nothing-to-do. Fails CLOSED:
        // a `UserData/` that exists but cannot be listed counts as
        // something left - ambiguity must block the delete, not
        // wave it through.
        func nothingLeftBehind() -> Bool {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: container.userDataURL.path, isDirectory: &isDirectory) {
                guard
                    let entries = try? fm.contentsOfDirectory(
                        atPath: container.userDataURL.path),
                    entries.isEmpty
                else { return false }
            }
            return PortableGameSaves.entryNames(
                atGameRoot: container.gameURL, fm: fm
            ).isEmpty
        }

        if nothingLeftBehind() { return true }

        // Verify the shared destination exists BEFORE any staging
        // move: staging pulls portable saves out of `Game/`, which
        // is one-way - if the rescue then aborted, a KEPT
        // portable-mode game would no longer see its own saves.
        let resolved = resolveAndPrepare(for: container)
        guard resolved.path != container.userDataURL.path else { return false }

        stagePortableSaves(of: container, fm: fm)
        drainLock.withLock { _ in
            _ = LegacyDataDrain.drain(from: container.userDataURL, into: resolved, fm: fm)
        }
        return nothingLeftBehind()
    }

    /// Move portable-mode saves out of `Game/` into the `UserData/`
    /// staging directory, where the regular drain picks them up
    /// (mtime merge, displaced-name conflicts, never a clobber).
    /// Best-effort; `rescueUserDataBeforeDeletion` re-checks the
    /// disk afterward.
    ///
    /// Save FOLDERS flatten one level: the runtime save model is
    /// flat (`Save Data/x.rxdata` resolves to `<data>/x.rxdata`),
    /// so the folder's children stage individually. Moving the
    /// folder whole would park the saves at
    /// `Data/<bucket>/<folder>/` - a path no game ever reads
    /// after a re-import.
    private static func stagePortableSaves(
        of container: GameContainer, fm: FileManager
    ) {
        let names = PortableGameSaves.entryNames(atGameRoot: container.gameURL, fm: fm)
        guard !names.isEmpty else { return }

        try? fm.createDirectory(at: container.userDataURL, withIntermediateDirectories: true)
        for name in names {
            let source = container.gameURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                let children = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
                for child in children {
                    stageEntry(
                        source.appendingPathComponent(child),
                        as: child, of: container, fm: fm)
                }
                if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                    try? fm.removeItem(at: source)
                }
            } else {
                stageEntry(source, as: name, of: container, fm: fm)
            }
        }
    }

    private static func stageEntry(
        _ source: URL, as name: String, of container: GameContainer, fm: FileManager
    ) {
        let target = UniqueFileName.firstAvailableURL(
            in: container.userDataURL, preferring: name, fm: fm)
        do {
            try fm.moveItem(at: source, to: target)
        } catch {
            NSLog(
                "[DataDirectory] Failed to stage portable save %@ of %@: %@",
                name,
                container.folderName,
                error.localizedDescription)
        }
    }

    private static func logDrain(
        _ outcome: LegacyDataDrain.Outcome,
        container: GameContainer,
        destination: URL
    ) {
        guard outcome.movedCount > 0 || !outcome.failures.isEmpty else { return }
        NSLog(
            "[DataDirectory] Drained UserData of %@ into %@ (%ld moved, %ld failed)",
            container.folderName,
            destination.path,
            outcome.movedCount,
            outcome.failures.count)
    }
}
