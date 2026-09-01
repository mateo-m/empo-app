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

    /// How far the run is on this game, or `nil` before the plan
    /// freezes.
    func progress(of gameId: String) -> Double? {
        BackupRunMonitor.shared.fraction(
            ofGame: BackupKeys.gameKey(containerFolderName: gameId))
    }

    /// Reads every game in one open of the state store.
    func refresh(games: [BackupBadgeGame]) {
        let descriptors = BackupTargets.load()
        guard !descriptors.isEmpty else {
            badgesByGameId = [:]
            banner = nil
            return
        }

        let store = try? BackupStateStore(url: BackupRoot.stateDatabase)
        defer { store?.close() }
        let running = BackupScheduler.shared.runningGameKeys
        let now = Date()

        var badges: [String: GameBackupBadge] = [:]
        var clocks: [GameFreshness] = []
        for game in games {
            let gameKey = BackupKeys.gameKey(containerFolderName: game.id)
            let targets = GameBackupStatusReader.targets(
                gameKey: gameKey, descriptors: descriptors, store: store)
            let status = GameBackupStatusRules.status(
                targets: targets, isRunning: running.contains(gameKey), now: now)
            badges[game.id] = status.badge
            clocks.append(
                GameBackupStatusReader.freshness(
                    gameKey: gameKey, lastPlayedAt: game.lastPlayed, targets: targets, now: now))
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
