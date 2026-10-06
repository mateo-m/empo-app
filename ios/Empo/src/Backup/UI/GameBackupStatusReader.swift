import Foundation
import GameProbe

/// What every screen that shows a game's backup state reads, per
/// SPEC 13.16.
///
/// The status line of the Backup sheet, the card badge of 13.3, and
/// the 21-day banner of 7.1 all come out of one read, so they can
/// never disagree.
@MainActor
enum GameBackupStatusReader {

    /// One game on every configured target. The caller opens the
    /// store, so a whole library costs one open.
    static func read(
        gameKey: String,
        lastPlayedAt: Date?,
        descriptors: [TargetDescriptor],
        store: BackupStateStore?,
        now: Date
    ) -> GameBackupRead {
        let network = BackupScheduler.shared.networkCause
        let targets = descriptors.map { descriptor in
            let clock = try? store?.staleness(targetId: descriptor.id, gameKey: gameKey)
            let failure = (try? store?.targetStatus(targetId: descriptor.id))?.failure
            let tally =
                (try? store?.partialTally(targetId: descriptor.id, gameKey: gameKey)) ?? [:]
            return GameTargetState(
                targetId: descriptor.id,
                displayName: descriptor.displayName,
                isPaused: descriptor.isPaused,
                cause: StaleCause.of(failure) ?? PartialPathClock.cause(tally) ?? network,
                lastSuccessAt: clock?.lastSuccessAt,
                lastPlayedAt: lastPlayedAt)
        }
        return GameBackupRead(
            status: GameBackupStatusRules.status(
                targets: targets,
                isRunning: BackupRunMonitor.shared.runningGameKeys.contains(gameKey),
                now: now),
            freshness: Staleness.worst(gameKey: gameKey, of: targets.map(\.freshness), now: now),
            lastSuccessAt: targets.compactMap(\.lastSuccessAt).max())
    }
}

/// One game's backup state, read once.
struct GameBackupRead {
    var status: GameBackupStatus
    var freshness: GameFreshness
    var lastSuccessAt: Date?
}
