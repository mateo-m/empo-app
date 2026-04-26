import Foundation

enum GameStatus: Hashable {
    case ready
    case importing(progress: Double) // 0.0 to 1.0
    case invalid

    /// Strips associated values - useful as an animation trigger.
    enum Phase: Hashable { case ready, importing, invalid }
    var phase: Phase {
        switch self {
        case .ready: .ready
        case .importing: .importing
        case .invalid: .invalid
        }
    }
}

struct GameEntry: Identifiable, Hashable {
    /// Bare UUID (matches `container?.id`). Stable across renames
    /// of the on-disk folder. Synthetic entries (in-flight imports
    /// without a committed folder yet) keep their id but have no
    /// `container`.
    let id: String

    /// `Documents/Games/<uuid>-<slug>/` for ready entries.
    /// nil during pre-flight validation when nothing is on disk
    /// yet (the synthetic placeholder entry shown in the grid).
    let container: GameContainer?

    let title: String        // display title (custom override or base)
    let artworkPath: String? // resolved artwork path
    // The engine's own title for the game (parsed from Game.ini),
    // surfaced on the library card alongside `title` when they
    // differ. Non-nil only when the display title has been
    // overridden - by a user-set customTitle or a JGP manifest
    // name - so users can still see what the game calls itself
    // inside the RGSS runtime. nil means `title` IS the engine
    // title and showing it twice would be redundant.
    var engineTitle: String? = nil
    var lastPlayed: Date? = nil      // from metadata, cached at scan time
    var status: GameStatus = .ready

    /// Where the game's own files live. `<container>/Game/`. Empty
    /// string for synthetic in-flight imports without a committed
    /// folder. Use this when you need to point the engine cwd at
    /// the game (`mkxp_setGamePath`), parse `Game.ini`, scan for
    /// title artwork, etc.
    var path: String {
        container?.gameURL.path ?? ""
    }

    var isImporting: Bool {
        if case .importing = status { return true }
        return false
    }

    var importProgress: Double {
        if case .importing(let p) = status { return p }
        return 0
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.title == rhs.title
            && lhs.container == rhs.container && lhs.artworkPath == rhs.artworkPath
            && lhs.engineTitle == rhs.engineTitle && lhs.lastPlayed == rhs.lastPlayed
    }


    static func parseINITitle(at gameDir: URL) -> String? {
        parseINIValue(at: gameDir, section: "game", key: "title")
    }

    static func parseINIValue(at gameDir: URL, section: String, key: String) -> String? {
        let fm = FileManager.default
        let iniURL: URL? = {
            let gameIni = gameDir.appendingPathComponent("Game.ini")
            if fm.fileExists(atPath: gameIni.path) { return gameIni }
            if let items = try? fm.contentsOfDirectory(atPath: gameDir.path) {
                for item in items where item.lowercased().hasSuffix(".ini") {
                    return gameDir.appendingPathComponent(item)
                }
            }
            return nil
        }()
        guard let iniURL else { return nil }
        return parseINIValue(in: iniURL, section: section, key: key)
    }

    static func parseINIValue(in iniURL: URL, section: String, key: String) -> String? {
        // Game.ini is typically Windows-1252 / Latin-1 (RPG Maker's
        // default save encoding). Try UTF-8 first - it's a strict
        // superset of ASCII so the common case Just Works - and
        // fall back to ISO Latin-1 when UTF-8 decode fails (any
        // file with a non-ASCII byte like the `é` in
        // "Title=Pokémon ..." trips this). Without the fallback,
        // titles with accented characters silently return nil and
        // surface as "Unknown Game" in the library.
        guard let raw = try? Data(contentsOf: iniURL) else { return nil }
        guard let data = String(data: raw, encoding: .utf8)
            ?? String(data: raw, encoding: .isoLatin1)
        else {
            return nil
        }

        let sectionLower = "[\(section)]"
        var inSection = false
        let keyPrefix = "\(key)="
        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.lowercased().hasPrefix(sectionLower)
                continue
            }
            if inSection && trimmed.lowercased().hasPrefix(keyPrefix) {
                let value = String(trimmed.dropFirst(keyPrefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
