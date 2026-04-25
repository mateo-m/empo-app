import Foundation

/// Per-game *managed-config* state directory.
///
/// `Documents/Games/<id>/` holds the game files exactly as they
/// were imported - we never write into it. `Documents/EmpoState/<id>/`
/// holds everything Empo generates per-game (mkxp.json,
/// patches.json, game_settings.json), so the imported game folder
/// stays a faithful mirror of the source archive.
///
/// At launch the engine is told about this directory via
/// `mkxp_setManagedConfigDir`, and its config / patcher loaders
/// check there before falling back to cwd.
enum EmpoState {

    private static let stateRoot = "EmpoState"

    /// Resolve the per-game state directory, creating it on first
    /// access. Always returns a usable URL even if creation fails
    /// (callers' I/O attempts will surface the real error).
    static func directory(forGameId gameId: String) -> URL {
        let dir = root().appendingPathComponent(gameId, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// Root state directory for ALL games.
    static func root() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return docs.appendingPathComponent(stateRoot, isDirectory: true)
    }

    /// Delete the per-game state directory (e.g. when a game is
    /// removed from the library). Safe to call even if the
    /// directory doesn't exist.
    static func remove(forGameId gameId: String) {
        let dir = root().appendingPathComponent(gameId)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Snapshot the developer-shipped `mkxp.json` (if any) from the
    /// imported game folder into `<stateDir>/mkxp.original.json`.
    ///
    /// `mkxp.original.json` is consumed by
    /// `GameSettings.readGameDefaults` (to populate the "default"
    /// rows in the Game Settings sheet with the developer's
    /// intended values) and by `GameSettings.applyToConfig` as the
    /// merge base, so values the developer specified that we
    /// haven't overridden in our settings UI (e.g. `customScript`,
    /// font lists, audio rates) are preserved on every regeneration
    /// of `<stateDir>/mkxp.json`.
    ///
    /// Idempotent: only copies when the destination doesn't already
    /// exist. Run at every launch (cheap I/O when there's nothing
    /// to do) so an existing import without a snapshot - either
    /// from a build before this hook landed, or from a JGP whose
    /// state dir was created before the developer mkxp.json was
    /// present - gets backfilled lazily without a forced upgrade
    /// pass. If the game folder has no mkxp.json the snapshot is
    /// simply absent and downstream code falls through to the
    /// (currently empty) state-dir mkxp.json + engine defaults.
    static func snapshotOriginalConfig(forGameId gameId: String,
                                       gameDirectory: URL) {
        let fm = FileManager.default
        let stateDir = directory(forGameId: gameId)
        let dest = stateDir.appendingPathComponent("mkxp.original.json")
        guard !fm.fileExists(atPath: dest.path) else { return }
        let source = gameDirectory.appendingPathComponent("mkxp.json")
        guard fm.fileExists(atPath: source.path) else { return }
        try? fm.copyItem(at: source, to: dest)
    }
}
