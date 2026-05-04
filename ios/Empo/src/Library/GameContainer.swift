import Foundation

/// Single source of truth for the on-disk layout of an imported game.
///
/// Everything related to one game is co-located inside
/// `Documents/Games/<uuid>-<slug>/`:
///
///   ```
///   Documents/Games/<uuid>-<slug>/
///   ├── Game/              Imported game files. NEVER written by Empo
///   │                      after import - we treat it as read-only.
///   ├── EmpoState/         Empo-managed state:
///   │                        - mkxp.json (generated config; merged
///   │                          from Game/mkxp.json + per-game settings)
///   │                        - patches.json (merged curated patches)
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
/// `GameContainer` is purely value-typed URL math; calling its
/// initializers and properties has zero side effects. Only the
/// explicit `ensure*` and `*delete*` helpers, and the snapshot
/// helper, touch the filesystem.
struct GameContainer: Equatable, Hashable {

    // MARK: - Identity

    /// The UUID portion of the folder name (first 36 chars). The
    /// stable, lookup-friendly id used everywhere outside of disk
    /// paths (UserDefaults keys, in-memory dicts, debug logs).
    let id: String

    /// `<uuid>-<slug>` (or `<uuid>` when slug is empty).
    let folderName: String

    /// `Documents/Games/<folderName>/`.
    let url: URL

    // MARK: - Subdirectory URLs

    var gameURL: URL {
        url.appendingPathComponent("Game", isDirectory: true)
    }

    var empoStateURL: URL {
        url.appendingPathComponent("EmpoState", isDirectory: true)
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

    var patchesURL: URL {
        empoStateURL.appendingPathComponent("patches.json")
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

    /// Build a container for a fresh import. Generates the path
    /// from a UUID + slug; doesn't touch disk.
    init(id: String, slug: String?) {
        let trimmed = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folderName = trimmed.isEmpty ? id : "\(id)-\(trimmed)"
        self.id = id
        self.folderName = folderName
        self.url = GameContainer.rootURL
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Build a container from the on-disk folder name. Returns nil
    /// if the folder name doesn't begin with a parseable UUID
    /// (defends against misc. files / orphan folders that may sit
    /// under `Games/` from earlier dev builds).
    init?(folderName: String) {
        guard folderName.count >= 36 else { return nil }
        let uuidPart = String(folderName.prefix(36))
        guard UUID(uuidString: uuidPart) != nil else { return nil }
        self.id = uuidPart
        self.folderName = folderName
        self.url = GameContainer.rootURL
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Build a container from an absolute URL pointing at the
    /// container directory itself (`Games/<folderName>/`).
    init?(url: URL) {
        self.init(folderName: url.lastPathComponent)
    }

    // MARK: - Roots

    /// Parent of all game containers. `Documents/Games/`.
    static let rootURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Games", isDirectory: true)

    // MARK: - Discovery

    /// Enumerate all containers currently on disk. A subfolder of
    /// `Games/` is only treated as a valid container if its name
    /// parses as `<uuid>` or `<uuid>-<slug>` AND it is a directory.
    /// `Game/` subdir presence is checked separately by the caller
    /// because half-imported / corrupt entries should still surface
    /// as invalid library cards rather than silently disappearing.
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

    /// Create the container directory and its four canonical
    /// subdirs. Idempotent; safe to call repeatedly.
    func ensureSubdirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gameURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: empoStateURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    /// Set `NSURLIsExcludedFromBackupKey` on the container so iCloud
    /// + iTunes backups skip the entire game tree (including Game/,
    /// EmpoState/, Logs/, Metadata/; iOS propagates the flag to a
    /// directory's contents).
    ///
    /// Why we exclude everything for now: the per-game id is a
    /// fresh `UUID()` minted at import time, so a backup of one
    /// device's `Documents/Games/<id>/EmpoState/` won't match any
    /// container on a different device (or even the same device
    /// after a re-import) - the saves and metadata would orphan
    /// silently. Until we have a content-based fingerprint that
    /// produces a stable id across imports, backing up per-game
    /// state can only mislead users about what's recoverable.
    /// Game/ is also re-importable from the source archive at zero
    /// data cost, so excluding the entire tree is strictly the
    /// right call.
    ///
    /// Idempotent: setting the flag on an already-excluded URL is
    /// a no-op (and silently swallowed if the URL is missing - a
    /// container that hasn't been created yet just won't have the
    /// attribute, which is fine).
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

    /// Recursively delete the entire container directory. One
    /// `rm -rf` removes Game/, EmpoState/, Logs/, Metadata/ - and
    /// thus all per-game saves, settings, logs, custom artwork,
    /// crash markers - in a single call.
    func deleteAll() throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Slug helper

    /// Lowercase, alphanumerics + dashes, no leading/trailing
    /// dashes. Used by `init(id:slug:)` callers to produce a
    /// filesystem-safe folder-name suffix from the game's title.
    static func slugify(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug =
            string
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return
            slug
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// If `dir` contains exactly one directory entry (ignoring
    /// macOS metadata and hidden files), returns that directory.
    /// Otherwise returns `dir` itself.
    ///
    /// Archive imports often wrap the game in a single top-level
    /// folder; raw folder imports usually drop the files at the
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
