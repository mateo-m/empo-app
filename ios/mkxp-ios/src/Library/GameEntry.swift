import Foundation

struct GameEntry: Identifiable, Hashable {
    let id: String           // UUID used as folder name
    let path: String         // full path to game folder
    let title: String        // from Game.ini [Game] Title=, or source name
    let artworkPath: String? // first image in Graphics/Titles/, if any
    var isImporting: Bool = false
    var importProgress: Double = 0 // 0.0 to 1.0

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool { lhs.id == rhs.id }
}
