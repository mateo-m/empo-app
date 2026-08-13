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

    /// Parent of the portable-save rescue buckets.
    /// `Documents/Rescued Saves/`. Portable saves must NOT go into
    /// `Data/`: that tree replicates Windows paths OUTSIDE a game's
    /// folder, and a re-imported game reads portable saves from
    /// `Game/`, never from there.
    static let rescuedSavesRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(RescuedSaves.directoryName, isDirectory: true)

    /// The shared font pool. `Documents/Fonts/`. One store for
    /// every game, like the Windows system font folder: the engine
    /// mounts it behind each game's own `Fonts/`, and the compat
    /// layer routes Essentials font-installer writes into it. A
    /// font dropped here once serves the whole library. It stays
    /// outside `Data/` because that tree holds per-game state;
    /// fonts are system state and survive game deletion.
    static let fontsRootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fonts", isDirectory: true)

    /// The engine mounts the pool at session start, so the folder
    /// must exist by then. Creation is cheap and idempotent. A
    /// failure only disables the pool (the engine skips a missing
    /// mount), but it is logged: the visible symptom - font
    /// installers that ask again on every launch - appears far
    /// from the cause, e.g. a user-created FILE named "Fonts" in
    /// the Empo folder.
    static func ensureFontsRoot() {
        do {
            try FileManager.default.createDirectory(
                at: fontsRootURL, withIntermediateDirectories: true)
        } catch {
            NSLog(
                "[DataDirectory] Could not create the shared Fonts folder: %@",
                "\(error)")
        }
    }

    /// Transient sibling of `Game/` inside a container holding
    /// portable saves pulled out during a deletion rescue, until
    /// the drain lands them in the rescue bucket. Dot-prefixed:
    /// hidden from library discovery. Non-empty means the rescue
    /// did not finish - the delete must stay blocked.
    static let rescueStagingDirectoryName = ".save-rescue-staging"

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
        let iniTitle = GameINI.gameTitle(at: container.gameURL)
        let components = dataPath.sharedDirectoryComponents(
            iniTitleFallback: iniTitle,
            folderNameFallback: container.folderName
        )

        let fm = FileManager.default
        var url = sharedRootURL
        for component in components {
            var chosen = DirectoryNameMatch.preferringExisting(
                component, among: fm.subdirectoryNames(at: url))
            // Heal mojibake-era directory names in place. The
            // matcher keeps such a directory reachable even when
            // the rename fails (a concurrent session, an iCloud
            // hold), so this is an upgrade, not a requirement.
            // Case-variant reuse stays a reuse: that behavior is
            // the desktop save-sharing contract, not a defect.
            if chosen != component,
                DirectoryNameMatch.legacyMojibakeRendering(of: component) == chosen
            {
                let legacyURL = url.appendingPathComponent(chosen, isDirectory: true)
                let healedURL = url.appendingPathComponent(component, isDirectory: true)
                if (try? fm.moveItem(at: legacyURL, to: healedURL)) != nil {
                    NSLog(
                        "[DataDirectory] Renamed mojibake data directory %@ -> %@",
                        chosen, component)
                    chosen = component
                }
            }
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
            healChains(in: staging, noticeName: container.folderName, fm: fm)
            return staging
        }

        let outcome = drainLock.withLock { _ in
            LegacyDataDrain.drain(from: container.userDataURL, into: resolved, fm: fm)
        }
        logDrain(outcome, container: container, destination: resolved)
        // Heal AFTER the drain: chained names inside a legacy
        // UserData/ tree drain over under their chained names and
        // must heal at the destination.
        healChains(in: resolved, noticeName: resolved.lastPathComponent, fm: fm)
        return resolved
    }

    // MARK: - Pre-literal save heal

    /// One pass over the whole shared `Data/` tree at app launch,
    /// so damaged saves reappear before the user opens anything.
    /// The per-game heal in `resolveAndPrepare` covers everything
    /// this pass cannot see yet (a legacy `UserData/` drain, a
    /// directory created later).
    @MainActor private static var didHealAtLaunch = false

    @MainActor
    static func healPreLiteralChainsAtLaunch() {
        guard !didHealAtLaunch else { return }
        didHealAtLaunch = true
        let fm = FileManager.default
        let outcome = drainLock.withLock { _ -> PreLiteralSaveHeal.Outcome in
            // One walk over the whole tree, one lock window. The
            // returned paths are Data/-relative, so their first
            // component IS the recovered game's directory name.
            let outcome = PreLiteralSaveHeal.healTree(at: sharedRootURL, fm: fm)
            for group in PreLiteralSaveHeal.groupedByTopDirectory(outcome.promoted) {
                recordSaveRecovery(name: group.directory, files: group.files)
            }
            return outcome
        }
        logHeal(outcome, root: sharedRootURL)
    }

    /// Heal one data directory tree and queue the one-time
    /// library sheet when anything was promoted. The record write
    /// happens under the same lock as the heal: recording is
    /// read-modify-write on the defaults blob, and two detached
    /// deletes may heal concurrently.
    private static func healChains(in directory: URL, noticeName: String, fm: FileManager) {
        let outcome = drainLock.withLock { _ -> PreLiteralSaveHeal.Outcome in
            let outcome = PreLiteralSaveHeal.healTree(at: directory, fm: fm)
            if !outcome.promoted.isEmpty {
                recordSaveRecovery(name: noticeName, files: outcome.promoted)
            }
            return outcome
        }
        logHeal(outcome, root: directory)
    }

    private static func logHeal(_ outcome: PreLiteralSaveHeal.Outcome, root: URL) {
        guard !outcome.isEmpty else { return }
        NSLog(
            "[DataDirectory] Recovered chained saves in %@ (%ld promoted, %ld failed): %@",
            root.path,
            outcome.promoted.count,
            outcome.failures.count,
            outcome.promoted.joined(separator: ", "))
    }

    /// Queue a recovery for the one-time sheet. The merge policy
    /// and encoding live in `SaveRecoveryLedger` (GameProbe) where
    /// the Linux CI tests pin them; this wrapper only adds the
    /// UserDefaults blob. Callers hold `drainLock`: the ledger
    /// update is read-modify-write and heals can run from detached
    /// delete tasks.
    private static func recordSaveRecovery(name: String, files: [String]) {
        let defaults = UserDefaults.standard
        let ledger = SaveRecoveryLedger.merging(
            pendingSaveRecoveries(), name: name, files: files, date: .now)
        guard let blob = SaveRecoveryLedger.encode(ledger) else { return }
        defaults.set(blob, forKey: DefaultsKey.pendingSaveRecoveries)
    }

    static func pendingSaveRecoveries() -> [SaveRecoveryLedger.Record] {
        SaveRecoveryLedger.decode(
            UserDefaults.standard.data(forKey: DefaultsKey.pendingSaveRecoveries))
    }

    static func clearPendingSaveRecoveries() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingSaveRecoveries)
    }

    // MARK: - Engine handoff spelling

    /// The spelling of `url` the engine must receive: every
    /// symlink resolved with POSIX `realpath`, so engine-side
    /// comparisons against `getcwd` output see one spelling. On
    /// device, app-container paths arrive as `/var/...` while
    /// `getcwd` resolves to `/private/var/...`. Foundation's
    /// `resolvingSymlinksInPath` is the WRONG tool here: it
    /// normalizes the other way (it strips `/private`).
    static func engineSpelling(of url: URL) -> URL {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            return url
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Rescue path for game deletion. Two save locations sit
    /// inside the doomed container tree, and they go to DIFFERENT
    /// homes:
    ///
    ///   - `UserData/` (a pre-0.5 container that never launched
    ///     under the shared-data scheme) holds env-derived saves:
    ///     it drains into the shared `Data/` directory, where the
    ///     engine serves them back to the game.
    ///   - "Portable mode" saves games keep NEXT TO their game
    ///     files (`Game/Game.rxdata`, a `Save Data/` folder - see
    ///     `PortableGameSaves`) move into a
    ///     `Rescued Saves/<title>/` bucket with their structure
    ///     intact, so a later import of the same game can put them
    ///     back into `Game/`. Only the deletion rescue may move
    ///     these: an installed game needs them exactly where they
    ///     are.
    ///
    /// Does nothing - and creates nothing - when there is nothing
    /// to rescue.
    ///
    /// Returns false when anything failed to move, including when
    /// a destination itself cannot exist (for `UserData/`, the
    /// fallback destination IS `UserData/`, and draining a
    /// directory into itself proves nothing). The caller must NOT
    /// delete the container in that case: silent save loss is
    /// never on the table.
    static func rescueUserDataBeforeDeletion(of container: GameContainer) -> Bool {
        let fm = FileManager.default
        let rescueStaging = container.url.appendingPathComponent(
            rescueStagingDirectoryName, isDirectory: true)

        // What still needs rescuing is judged from disk, not from
        // what any step claims: a save whose move FAILED must
        // count as unrescued, not as nothing-to-do. Fails CLOSED:
        // a directory that exists but cannot be listed counts as
        // something left - ambiguity must block the delete, not
        // wave it through.
        func hasLeftoverContent(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            guard isDirectory.boolValue,
                let entries = try? fm.contentsOfDirectory(atPath: url.path)
            else { return true }
            return !entries.isEmpty
        }
        func nothingLeftBehind() -> Bool {
            !hasLeftoverContent(container.userDataURL)
                && !hasLeftoverContent(rescueStaging)
                && PortableGameSaves.entryNames(
                    atGameRoot: container.gameURL, fm: fm
                ).isEmpty
        }

        if nothingLeftBehind() { return true }

        var rescued = true
        if hasLeftoverContent(container.userDataURL) {
            // Verify the shared destination before draining; the
            // fallback path means the destination could not exist.
            let resolved = resolveAndPrepare(for: container)
            if resolved.path == container.userDataURL.path {
                rescued = false
            } else {
                drainLock.withLock { _ in
                    _ = LegacyDataDrain.drain(
                        from: container.userDataURL, into: resolved, fm: fm)
                }
            }
        }
        if rescued {
            rescuePortableSaves(of: container, staging: rescueStaging, fm: fm)
        }
        return nothingLeftBehind()
    }

    /// Move portable-mode saves out of `Game/` into the rescue
    /// bucket for this game, via a container-local staging
    /// directory: entries first move (whole, structure intact)
    /// into the staging directory, then `LegacyDataDrain` merges
    /// the staging into the bucket (mtime merge, displaced-name
    /// conflicts, never a clobber). A partial failure leaves the
    /// remainder in the staging directory, which blocks the delete
    /// and resumes on the next attempt.
    ///
    /// The bucket is verified to exist BEFORE any entry leaves
    /// `Game/`: pulling saves out is one-way, and if the rescue
    /// then aborted, a KEPT portable-mode game would no longer see
    /// its own saves.
    ///
    /// The bucket carries an identity marker with the container's
    /// INI-derived folder name, so a later import can match it
    /// even though the bucket itself is named by display title
    /// (custom title first).
    private static func rescuePortableSaves(
        of container: GameContainer, staging: URL, fm: FileManager
    ) {
        let names = PortableGameSaves.entryNames(atGameRoot: container.gameURL, fm: fm)
        guard !names.isEmpty || hasContent(staging, fm: fm) else { return }

        let bucket = rescueBucket(for: container, fm: fm)
        var isDirectory: ObjCBool = false
        try? fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: bucket.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            NSLog(
                "[DataDirectory] Cannot create rescue bucket %@; keeping saves in place",
                bucket.path)
            return
        }
        RescuedSaves.writeMarker(
            .init(folderName: container.folderName), inBucket: bucket, fm: fm)

        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in names {
            let source = container.gameURL.appendingPathComponent(name)
            let target = UniqueFileName.firstAvailableURL(
                in: staging, preferring: name, fm: fm)
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
        let outcome = drainLock.withLock { _ in
            LegacyDataDrain.drain(from: staging, into: bucket, fm: fm)
        }
        NSLog(
            "[DataDirectory] Rescued portable saves of %@ into %@ (%ld moved, %ld failed)",
            container.folderName,
            bucket.path,
            outcome.movedCount,
            outcome.failures.count)
    }

    /// `Rescued Saves/<display title>/`, reusing an existing
    /// bucket case-insensitively the way `resolve` does for
    /// `Data/` components.
    private static func rescueBucket(for container: GameContainer, fm: FileManager) -> URL {
        let metadata = GameMetadata.load(from: container)
        let iniTitle = GameINI.gameTitle(at: container.gameURL)
        let title =
            metadata.customTitle ?? metadata.baseTitle ?? iniTitle ?? container.folderName
        let name = GameFolderName.sanitize(title)

        let chosen = DirectoryNameMatch.preferringExisting(
            name, among: fm.subdirectoryNames(at: rescuedSavesRootURL))
        return rescuedSavesRootURL.appendingPathComponent(chosen, isDirectory: true)
    }

    private static func hasContent(_ url: URL, fm: FileManager) -> Bool {
        ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty == false
    }

    /// Import-side restore: drain every rescue bucket that belongs
    /// to `container` (marker identity first, bucket name as the
    /// fallback) back into its fresh `Game/` tree. Called after a
    /// fresh import lands, before the first launch, so the game
    /// sees its saves on the first run. Complete restores remove
    /// their emptied buckets; a partial restore keeps the rest for
    /// the next import.
    static func restoreRescuedSaves(for container: GameContainer) {
        let fm = FileManager.default
        let buckets = RescuedSaves.matchingBuckets(
            in: rescuedSavesRootURL, folderName: container.folderName, fm: fm)
        guard !buckets.isEmpty else { return }

        for bucket in buckets {
            let outcome = drainLock.withLock { _ in
                RescuedSaves.restore(from: bucket, into: container.gameURL, fm: fm)
            }
            NSLog(
                "[DataDirectory] Restored rescued saves from %@ into %@ (%ld moved, %ld failed)",
                bucket.lastPathComponent,
                container.folderName,
                outcome.movedCount,
                outcome.failures.count)
        }
        // An emptied root is clutter in the Files app; remove it
        // only when the LAST bucket is gone.
        if ((try? fm.contentsOfDirectory(atPath: rescuedSavesRootURL.path)) ?? []).isEmpty {
            try? fm.removeItem(at: rescuedSavesRootURL)
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
