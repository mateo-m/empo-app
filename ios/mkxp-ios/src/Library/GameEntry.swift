import Foundation

enum GameStatus: Hashable {
    case ready
    case importing(progress: Double) // 0.0 to 1.0
    case invalid

    /// Strips associated values — useful as an animation trigger.
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
    var lastPlayed: Date? = nil      // from metadata, cached at scan time
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
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.title == rhs.title && lhs.path == rhs.path && lhs.artworkPath == rhs.artworkPath && lhs.originalTitle == rhs.originalTitle && lhs.lastPlayed == rhs.lastPlayed
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
        guard let data = try? String(contentsOf: iniURL, encoding: .utf8) else {
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
