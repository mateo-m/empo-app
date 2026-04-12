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
    let title: String        // from Game.ini [Game] Title=, or source name
    let artworkPath: String? // first image in Graphics/Titles/, if any
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
    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool { lhs.id == rhs.id }
}
