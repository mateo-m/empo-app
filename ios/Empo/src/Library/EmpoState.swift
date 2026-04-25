import Foundation

/// Per-game *managed-config* state directory.
///
/// `Documents/Games/<id>/` holds the game files exactly as they
/// were imported - we never write into it. `Documents/EmpoState/<id>/`
/// holds everything Empo generates per-game (mkxp.json,
/// patches.json, game_settings.json, configuration.json), so the
/// imported game folder stays a faithful mirror of the source
/// archive.
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

    /// Root state directory for ALL games. Caller may iterate
    /// children to enumerate per-game state dirs (used by
    /// migration logic).
    static func root() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return docs.appendingPathComponent(stateRoot, isDirectory: true)
    }

    /// Filenames that the migration moves from a game folder into
    /// the matching state directory. Keep in sync with the union
    /// of: `GameSettings` (game_settings.json), cheats sidecar
    /// (configuration.json), engine config (mkxp.json,
    /// mkxp.original.json), and patcher distribution
    /// (patches.json).
    static let managedFilenames: [String] = [
        "mkxp.json",
        "mkxp.original.json",
        "patches.json",
        "game_settings.json",
        "configuration.json",
    ]

    /// Move any of the managed filenames that currently sit inside
    /// `gameDirectory` into the game's state directory.
    /// Idempotent: a managed file already present in the state dir
    /// wins over a stale copy in the game folder, which is
    /// deleted to clean the game directory.
    ///
    /// Run at every game launch (cheap I/O when there's nothing
    /// to move) so games imported before EmpoState shipped are
    /// migrated lazily without a forced one-shot upgrade pass.
    static func migrateLegacyConfig(forGameId gameId: String,
                                    gameDirectory: URL) {
        let fm = FileManager.default
        let stateDir = directory(forGameId: gameId)
        for name in managedFilenames {
            let source = gameDirectory.appendingPathComponent(name)
            let dest = stateDir.appendingPathComponent(name)

            guard fm.fileExists(atPath: source.path) else { continue }

            if fm.fileExists(atPath: dest.path) {
                /* State dir already has the canonical copy. The
                 * game-folder version is stale (older write or
                 * pre-migration leftover). Delete it so the
                 * game folder stays pristine. */
                try? fm.removeItem(at: source)
                continue
            }

            try? fm.moveItem(at: source, to: dest)
        }
    }

    /// Delete the per-game state directory (e.g. when a game is
    /// removed from the library). Safe to call even if the
    /// directory doesn't exist.
    static func remove(forGameId gameId: String) {
        let dir = root().appendingPathComponent(gameId)
        try? FileManager.default.removeItem(at: dir)
    }
}
