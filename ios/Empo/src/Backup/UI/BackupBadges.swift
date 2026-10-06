import Foundation
import GameProbe

/// The card badges of SPEC 13.3 and the one library banner of 7.1.
///
/// Staleness has three homes and no more: this badge at 7 days, the
/// banner at 21 days, and the status line in the Backup sheet. All
/// three read `GameBackupStatusReader`, so they never disagree.
@MainActor
@Observable
final class BackupBadges {

    static let shared = BackupBadges()

    private init() {}

    /// Where the badge pass reads the library. `GameLibraryView`
    /// gives it once, so a write that changes a badge refreshes
    /// without the view.
    private var readTheLibrary: (@MainActor () -> [BackupBadgeGame])?
    private var badgesByGameId: [String: GameBackupBadge] = [:]
    /// The one banner the library shows at 21 days, or `nil` while
    /// no game reached the mark.
    private(set) var banner: LibraryStaleBanner?
    private(set) var bannerTargetLabel: String?

    /// The state one card draws. A game that is backed up and
    /// current gets none, which is invariant 9.
    func badge(of gameId: String) -> GameBackupBadge {
        badgesByGameId[gameId] ?? .none
    }

    /// The library the badges count. The view gives it once.
    func reads(_ library: @escaping @MainActor () -> [BackupBadgeGame]) {
        readTheLibrary = library
        refresh()
    }

    /// Every write that changes a badge calls this: a run that
    /// starts, a run that ends, and a target added, paused, or
    /// removed.
    func invalidate() {
        refresh()
    }

    /// Reads every game in one open of the state store.
    private func refresh() {
        guard let games = readTheLibrary?() else { return }
        let descriptors = BackupTargets.load()
        guard !descriptors.isEmpty else {
            badgesByGameId = [:]
            banner = nil
            return
        }

        let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase)
        defer { store?.close() }
        let now = Date()

        var badges: [String: GameBackupBadge] = [:]
        var clocks: [GameFreshness] = []
        for game in games {
            let gameKey = BackupKeys.gameKey(containerFolderName: game.id)
            let read = GameBackupStatusReader.read(
                gameKey: gameKey,
                lastPlayedAt: game.lastPlayed,
                descriptors: descriptors,
                store: store,
                now: now)
            badges[game.id] = read.status.badge
            clocks.append(read.freshness)
        }

        badgesByGameId = badges
        banner = Staleness.libraryBanner(clocks)
        bannerTargetLabel = banner?.targetId.flatMap { id in
            descriptors.first { $0.id == id }?.displayName
        }
    }

    /// The one action the banner carries, per 7.1. The two actions
    /// that start a run answer here. The rest lead to the Backups
    /// screen, where the target row of 13.5 carries the fix.
    func pressTheBanner() {
        guard let banner else { return }
        if banner.action == .allowThisRunOverCellular {
            BackupNetwork.allowsThisRunOverCellular = true
        }
        BackupScheduler.shared.pressBackUpNow(.library)
    }

    /// Whether the banner's action leads to the Backups screen
    /// instead of starting a run here.
    var bannerOpensTheBackupsScreen: Bool {
        switch banner?.action {
        case .signInAgain, .makeSpaceOnTheTarget, .freeSpaceOnThisDevice: return true
        case .allowThisRunOverCellular, .backUpNow, .none: return false
        }
    }
}

/// What the badge pass reads from one library entry.
struct BackupBadgeGame {
    var id: String
    var lastPlayed: Date?
}
