import Foundation

enum GameStatus: Hashable {
    case ready
    case importing(progress: Double) // 0.0 to 1.0
    case invalid

    /// The broad phase, ignoring associated values — useful as an animation trigger.
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
    let id: String           // UUID used as folder name
    let path: String         // full path to game folder
    let title: String        // display title (custom override or original)
    let artworkPath: String? // first image in Graphics/Titles/, if any
    var originalTitle: String? = nil // from Game.ini — non-nil only when a custom title is set
    var status: GameStatus = .ready

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
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.title == rhs.title && lhs.path == rhs.path && lhs.artworkPath == rhs.artworkPath && lhs.originalTitle == rhs.originalTitle
    }

    // MARK: - INI Parsing

    /// Reads the `Title=` value from the `[Game]` section of the game's .ini file.
    /// Returns nil if no .ini file is found or the title is empty.
    static func parseINITitle(at gameDir: URL) -> String? {
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
        guard let iniURL, let data = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return nil
        }

        var inGameSection = false
        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inGameSection = trimmed.lowercased().hasPrefix("[game]")
                continue
            }
            if inGameSection && trimmed.lowercased().hasPrefix("title=") {
                let value = String(trimmed.dropFirst("title=".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
