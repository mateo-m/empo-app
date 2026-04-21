import Foundation

/// Pure sorting helpers for the library view. Extracted so the sort
/// logic can be reviewed + tested in isolation and kept out of
/// GameLibraryView's body.

enum GameSorting {
    static func sort(_ games: [GameEntry], option: LibrarySortOption, sizes: [String: Int64]) -> [GameEntry] {
        switch option {
        case .titleAZ:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .recentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .leastRecentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        case .largestSize:
            return games.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .smallestSize:
            return games.sorted { (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0) }
        case .mostPlayed:
            return games.sorted { (playTime(for: $0) ?? 0) > (playTime(for: $1) ?? 0) }
        case .leastPlayed:
            return games.sorted { (playTime(for: $0) ?? 0) < (playTime(for: $1) ?? 0) }
        }
    }

    static func playTime(for game: GameEntry) -> TimeInterval? {
        GameMetadata.load(for: game.id).totalPlayTime
    }
}
