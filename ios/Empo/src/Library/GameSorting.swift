import Foundation

/// Sort logic for the library view. Lives on `LibrarySortOption` so adding
/// a new case is a compile error until it's handled here.
extension LibrarySortOption {
    func sort(_ games: [GameEntry], sizes: [String: Int64]) -> [GameEntry] {
        switch self {
        case .titleAZ:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .recentlyAdded:
            return games.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .leastRecentlyAdded:
            return games.sorted { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) }
        case .recentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .leastRecentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        case .largestSize:
            return games.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .smallestSize:
            return games.sorted { (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0) }
        case .mostPlayed:
            return games.sorted { ($0.totalPlayTime ?? 0) > ($1.totalPlayTime ?? 0) }
        case .leastPlayed:
            return games.sorted { ($0.totalPlayTime ?? 0) < ($1.totalPlayTime ?? 0) }
        }
    }

    /// True for the sorts that need the on-disk size map. Callers
    /// gate the (expensive) full-library directory walks on this.
    var usesDiskSizes: Bool {
        self == .largestSize || self == .smallestSize
    }
}
