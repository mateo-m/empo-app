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
///   │                        - mkxp.json (generated config)
///   │                        - mkxp.original.json (snapshot of the
///   │                          developer's shipped mkxp.json, if any)
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

    var mkxpOriginalConfigURL: URL {
        empoStateURL.appendingPathComponent("mkxp.original.json")
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
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> GameContainer? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
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
    }

    @discardableResult
    func ensureEmpoStateDirectory() -> URL {
        try? FileManager.default.createDirectory(
            at: empoStateURL, withIntermediateDirectories: true
        )
        return empoStateURL
    }

    @discardableResult
    func ensureMetadataDirectory() -> URL {
        try? FileManager.default.createDirectory(
            at: metadataURL, withIntermediateDirectories: true
        )
        return metadataURL
    }

    @discardableResult
    func ensureLogsDirectory() -> URL {
        try? FileManager.default.createDirectory(
            at: logsURL, withIntermediateDirectories: true
        )
        return logsURL
    }

    /// Recursively delete the entire container directory. One
    /// `rm -rf` removes Game/, EmpoState/, Logs/, Metadata/ - and
    /// thus all per-game saves, settings, logs, custom artwork,
    /// crash markers - in a single call.
    func deleteAll() throws {
        try FileManager.default.removeItem(at: url)
    }


    // MARK: - mkxp.json snapshot

    /// Snapshot the developer-shipped `mkxp.json` (if any) from
    /// `Game/` into `EmpoState/mkxp.original.json`.
    ///
    /// `mkxp.original.json` is consumed by
    /// `GameSettings.readGameDefaults` (to populate the "default"
    /// rows in the Game Settings sheet with the developer's
    /// intended values) and by `GameSettings.applyToConfig` as the
    /// merge base, so values the developer specified that we
    /// haven't overridden in our settings UI (e.g. `customScript`,
    /// font lists, audio rates) survive every regeneration of the
    /// state-dir mkxp.json.
    ///
    /// Idempotent: only copies when the destination doesn't exist.
    /// Run at every launch (cheap I/O when there's nothing to do)
    /// so an existing import without a snapshot - either from a
    /// build before this hook landed, or from a JGP whose state
    /// dir was created before the developer mkxp.json was present
    /// - gets backfilled lazily without a forced upgrade pass. If
    /// `Game/mkxp.json` doesn't exist the snapshot is simply
    /// absent and downstream code falls through to the engine
    /// defaults.
    func snapshotOriginalConfigIfNeeded() {
        let fm = FileManager.default
        let dest = mkxpOriginalConfigURL
        guard !fm.fileExists(atPath: dest.path) else { return }
        let source = gameURL.appendingPathComponent("mkxp.json")
        guard fm.fileExists(atPath: source.path) else { return }
        ensureEmpoStateDirectory()
        try? fm.copyItem(at: source, to: dest)
    }


    // MARK: - Slug helper

    /// Lowercase, alphanumerics + dashes, no leading/trailing
    /// dashes. Used by `init(id:slug:)` callers to produce a
    /// filesystem-safe folder-name suffix from the game's title.
    static func slugify(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = string
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return slug
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
