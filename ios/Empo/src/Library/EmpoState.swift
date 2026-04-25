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
}
