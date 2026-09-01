import Foundation
import GameProbe

/// What every screen that shows a game's backup state reads first,
/// per SPEC 13.16.
///
/// The status line of the Backup sheet and the card badge of 13.3
/// both take these target states into
/// `GameBackupStatusRules.status`, so the line and the badge can
/// never disagree.
@MainActor
enum GameBackupStatusReader {

    /// One game on every configured target. The caller opens the
    /// store, so a whole library costs one open.
    static func targets(
        gameKey: String, descriptors: [TargetDescriptor], store: BackupStateStore?
    ) -> [GameTargetState] {
        let network = BackupScheduler.shared.networkCause
        return descriptors.map { descriptor in
            let clock = try? store?.staleness(targetId: descriptor.id, gameKey: gameKey)
            let failure = (try? store?.targetStatus(targetId: descriptor.id))?.failure
            let tally =
                (try? store?.partialTally(targetId: descriptor.id, gameKey: gameKey)) ?? [:]
            return GameTargetState(
                targetId: descriptor.id,
                displayName: descriptor.displayName,
                isPaused: descriptor.isPaused,
                cause: StaleCause.of(failure) ?? PartialPathClock.cause(tally) ?? network,
                lastSuccessAt: clock?.lastSuccessAt)
        }
    }

    /// The clock inputs of 7.1 for the same game, which the card
    /// badge and the 21-day banner both count from.
    static func freshness(
        gameKey: String,
        lastPlayedAt: Date?,
        targets: [GameTargetState],
        now: Date
    ) -> GameFreshness {
        let clocks = targets.map {
            TargetFreshness(
                targetId: $0.targetId,
                isPaused: $0.isPaused,
                lastSuccessAt: $0.lastSuccessAt,
                lastPlayedAt: lastPlayedAt,
                cause: $0.cause)
        }
        return Staleness.worst(gameKey: gameKey, of: clocks, now: now)
    }
}
