import Foundation
import GameProbe

/// Single source of truth for the on-disk layout of an imported game.
///
/// Everything related to one game is co-located inside
/// `Documents/Games/<name>/`, where `<name>` is the game's title as
/// declared in its INI file (`Game.ini` or any other `*.ini` the
/// game ships), sanitized by `GameFolderName`:
///
///   ```
///   Documents/Games/<name>/
///   ├── Game/              Imported game files. NEVER written by Empo
///   │                      after import - we treat it as read-only.
///   ├── UserData/          Per-game writable payload (save files,
///   │                      backups, plugin data), exposed via Files app.
///   ├── EmpoState/         Empo-managed state:
///   │                        - mkxp.json (generated config; merged
///   │                          from Game/mkxp.json + per-game settings)
///   │                        - game_settings.json (per-game UI prefs)
///   │                        - .pokemon_essentials_detected (runtime
///   │                          marker written by pokemon_input.rb)
///   │                        - .session-active (crash-detection
///   │                          marker; present while a session runs)
///   ├── Logs/              Per-game session logs:
///   │                        - session-history.log (chronological
///   │                          list of session timestamps for this
///   │                          game; appended per session)
///   │                        - <iso8601>.log (per-session debug log,
///   │                          one per launch when debug logs are on)
///   └── Metadata/          Per-game metadata:
///                            - metadata.json (GameMetadata struct)
///                            - artwork.jpg / banner.jpg (custom user
///                              art or JGP-imported icon)
///                            - exe-icon.png (sidecar extracted from
///                              the game's .exe at import time)
///   ```
///
/// `GameContainer` is pure value-typed URL math. Calls to its
/// initializers and properties have zero side effects. Only the
/// explicit `ensure*` and `*delete*` helpers, and the snapshot
/// helper, touch the filesystem.
struct GameContainer: Equatable, Hashable {

    // MARK: - Identity

    /// The directory name under `Games/`: the sanitized game title.
    /// Doubles as the stable, lookup-friendly id used everywhere
    /// outside of disk paths (UserDefaults keys, in-memory dicts,
    /// debug logs). Before v0.5 the folder was `<uuid>-<slug>` and
    /// the id was the UUID prefix; `GameContainerMigration` renames
    /// those trees at launch.
    let folderName: String

    /// Alias of `folderName`, kept as the identity every consumer
    /// (GameEntry, pendingImports, controls persistence) keys on.
    var id: String { folderName }

    /// `Documents/Games/<folderName>/`.
    let url: URL

    // MARK: - Subdirectory URLs

    var gameURL: URL {
        url.appendingPathComponent("Game", isDirectory: true)
    }

    var empoStateURL: URL {
        url.appendingPathComponent("EmpoState", isDirectory: true)
    }

    var userDataURL: URL {
        url.appendingPathComponent("UserData", isDirectory: true)
    }

    var logsURL: URL {
        url.appendingPathComponent("Logs", isDirectory: true)
    }

    var metadataURL: URL {
        url.appendingPathComponent("Metadata", isDirectory: true)
    }

    // MARK: - Specific files

    var gameIniURL: URL {
        gameURL.appendingPathComponent("Game.ini")
    }

    var mkxpConfigURL: URL {
        empoStateURL.appendingPathComponent("mkxp.json")
    }

    var gameSettingsURL: URL {
        empoStateURL.appendingPathComponent("game_settings.json")
    }

    /// Player-edited touch layout + per-game controller overrides (SPEC §3).
    var userControlsURL: URL {
        empoStateURL.appendingPathComponent("controls.json")
    }

    var peDetectedMarkerURL: URL {
        empoStateURL.appendingPathComponent(".pokemon_essentials_detected")
    }

    var sessionActiveMarkerURL: URL {
        empoStateURL.appendingPathComponent(".session-active")
    }

    var sessionHistoryURL: URL {
        logsURL.appendingPathComponent("session-history.log")
    }

    var metadataJSONURL: URL {
        metadataURL.appendingPathComponent("metadata.json")
    }

    /// Sidecar PNG extracted from the game's `.exe` icon at import
    /// time. Lives under `Metadata/` so the `Game/` subtree stays
    /// untouched after the initial import.
    var exeIconSidecarURL: URL {
        metadataURL.appendingPathComponent(GameContainer.exeIconSidecarFilename)
    }

    // MARK: - Constants

    static let exeIconSidecarFilename = "exe-icon.png"

    // MARK: - Initializers

    /// Build a container from the on-disk folder name (or from a
    /// name that an import is about to create). Does not touch
    /// disk. A name that is not a safe single path component (the
    /// import planner and the migration never produce one) is
    /// coerced through `GameFolderName.sanitize` as a last-resort
    /// defense so the container can never point at `Games/` itself
    /// or escape it.
    init(folderName: String) {
        let name =
            GameContainer.isSafeFolderName(folderName)
            ? folderName
            : GameFolderName.sanitize(folderName)
        self.folderName = name
        self.url = GameContainer.rootURL
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Build a container from an absolute URL pointing at the
    /// container directory itself (`Games/<folderName>/`).
    init(url: URL) {
        self.init(folderName: url.lastPathComponent)
    }

    /// A name usable as a directory name directly under `Games/`:
    /// non-empty, a single component, not a dot-traversal, and not
    /// hidden.
    static func isSafeFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != ".." && !name.hasPrefix(".")
    }

    /// The `<uuid>` prefix of a pre-v0.5 `<uuid>-<slug>` folder
    /// name (the old container id), or nil for post-migration
    /// title-based names. `GameContainerMigration` uses this to
    /// recognize legacy trees.
    static func legacyUUIDPrefix(folderName: String) -> String? {
        ContainerMigrationPlanner.legacyUUIDPrefix(folderName: folderName)
    }

    // MARK: - Roots

    /// Parent of all game containers. `Documents/Games/`.
    static let rootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Games", isDirectory: true)

    // MARK: - Discovery

    /// Enumerate all containers currently on disk. Every non-hidden
    /// directory under `Games/` is a container. `Game/` subdir
    /// presence is checked separately by the caller because
    /// half-imported / corrupt entries should still surface as
    /// invalid library cards rather than silently disappearing.
    static func discover() -> [GameContainer] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return entries.compactMap { url -> GameContainer? in
            let isDir =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            guard isDir else { return nil }
            return GameContainer(url: url)
        }
    }

    // MARK: - Filesystem side effects

    /// Create the container directory and its canonical
    /// subdirs. Idempotent. Safe to call repeatedly.
    func ensureSubdirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gameURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: userDataURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: empoStateURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    /// Set `NSURLIsExcludedFromBackupKey` on the container so iCloud
    /// + iTunes backups skip the entire game tree: Game/,
    /// EmpoState/, Logs/, and Metadata/. iOS propagates the flag to
    /// a directory's contents.
    ///
    /// Why we exclude everything for now: game trees are large and
    /// re-importable from the source archive at zero data cost, so
    /// backing them up mostly bloats users' iCloud quota. Saves for
    /// games that declare `dataPathOrg`/`dataPathApp` live outside
    /// this tree (see `GameDataDirectory`) and stay backed up.
    /// Revisiting per-subtree exclusion (keep UserData/, drop
    /// Game/) is future work now that folder names are stable
    /// across imports.
    ///
    /// Idempotent: setting the flag on an already-excluded URL is
    /// a no-op. A missing URL is silently swallowed: a container
    /// that hasn't been created yet just won't have the attribute,
    /// which is fine.
    func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        // Mutating an immutable URL's resource values is the
        // standard pattern: assign a writable copy, call
        // `setResourceValues`, drop the copy. The actual change
        // lives on the filesystem inode, not the URL value.
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    /// `mkdir -p` the URL, then return it. Best-effort: errors
    /// during creation are swallowed because callers are about to
    /// hit a real failure (write permission, disk full) on the
    /// next operation anyway, with a clearer error site.
    @discardableResult
    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    func ensureUserDataDirectory() -> URL {
        Self.ensureDirectory(userDataURL)
    }

    @discardableResult
    func ensureEmpoStateDirectory() -> URL {
        Self.ensureDirectory(empoStateURL)
        // Older builds wrote a snapshot of the developer's
        // mkxp.json as `mkxp.original.json` here and used it as a
        // merge base. We now read directly from `Game/mkxp.json`
        // (the imported folder is immutable after import), so the
        // snapshot is dead state. Clean it up opportunistically.
        let staleSnapshot = empoStateURL.appendingPathComponent("mkxp.original.json")
        try? FileManager.default.removeItem(at: staleSnapshot)
        return empoStateURL
    }

    @discardableResult
    func ensureMetadataDirectory() -> URL {
        Self.ensureDirectory(metadataURL)
    }

    @discardableResult
    func ensureLogsDirectory() -> URL {
        Self.ensureDirectory(logsURL)
    }

    /// Append a single line to a file under `Logs/`. Creates the
    /// file on first write. Used for host-side manifest diagnostics.
    func appendLogLine(_ line: String, fileName: String) {
        ensureLogsDirectory()
        let path = logsURL.appendingPathComponent(fileName).path
        let entry = line.hasSuffix("\n") ? line : line + "\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        if let data = entry.data(using: .utf8),
            let fh = FileHandle(forWritingAtPath: path)
        {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        }
    }

    /// Recursively delete the entire container directory. One
    /// `rm -rf` removes Game/, EmpoState/, Logs/, and Metadata/ in
    /// a single call. That also removes all per-game saves,
    /// settings, logs, custom artwork, and crash markers.
    ///
    /// Archives and folder imports can land with read-only POSIX
    /// bits on `Game/` (common in Windows-origin zips). iOS refuses
    /// to unlink children through a non-writable directory, so we
    /// normalize owner-write permission on the tree first.
    func deleteAll() throws {
        let fm = FileManager.default
        try Self.makeTreeDeletable(at: url, fm: fm)
        try fm.removeItem(at: url)
    }

    /// Ensure every path under `url` is deletable by the app
    /// sandbox. Only touches owner-write. Leaves group/other as-is.
    private static func makeTreeDeletable(at url: URL, fm: FileManager) throws {
        try GameTreeUpdate.normalizeOwnerWritable(at: url, fm: fm)
    }

    /// Imported game trees sometimes arrive with a read-only `Game/`
    /// root (archive metadata or macOS copyItem). Empo never needs
    /// that for immutability. File content stays untouched. We only
    /// need owner-write so a future delete can recurse.
    static func normalizeImportedGamePermissions(at gameURL: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: gameURL.path
        )
    }

    /// If `dir` contains exactly one directory entry (ignoring
    /// macOS metadata and hidden files), returns that directory.
    /// Otherwise returns `dir` itself.
    ///
    /// Archive imports often wrap the game in a single top-level
    /// folder. Raw folder imports usually drop the files at the
    /// top level. This helper picks the right one.
    static func findGameRoot(
        in dir: URL,
        fm: FileManager = .default
    ) -> URL {
        guard
            let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return dir }

        let meaningful = items.filter { $0.lastPathComponent != "__MACOSX" }
        if meaningful.count == 1,
            let single = meaningful.first,
            (try? single.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        {
            return single
        }
        return dir
    }
}
