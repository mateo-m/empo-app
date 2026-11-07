import Foundation

/// The card at the top of the Backups screen, per SPEC 13.4.
///
/// It answers the only question most visits ask, in the
/// worst-enabled-target voice of 7.1.
public struct BackupsScreenStatus: Equatable, Sendable {

    /// The headline. "All games backed up", "Check Dropbox", or
    /// "Backups paused".
    public var line: String
    /// The line under the headline. The last backup, or the problem
    /// in the words of the row.
    public var detail: String?
    /// The target the card names, or `nil` where nothing is wrong.
    public var targetId: String?
    public var isHealthy: Bool

    public init(line: String, detail: String? = nil, targetId: String?, isHealthy: Bool) {
        self.line = line
        self.detail = detail
        self.targetId = targetId
        self.isHealthy = isHealthy
    }
}

public enum BackupsScreenStatusRules {

    public static let everythingPausedLine = screenText("Backups paused")
    public static let everythingPausedDetail = screenText("Every location is paused")
    public static let healthyLine = screenText("All games backed up")
    public static let readyLine = screenText("Ready to back up")

    /// The status, or `nil` where no target exists.
    ///
    /// A paused target leaves the computation. Two targets in the
    /// same state break the tie on the target id. `lastSuccessText`
    /// is the newest run in the caller's words, such as "today".
    public static func status(
        of targets: [TargetRowFacts], games: [LateGame] = [],
        lastSuccessText: String? = nil
    ) -> BackupsScreenStatus? {
        guard !targets.isEmpty else { return nil }
        let rows = targets.map(TargetRowRules.row)
        let enabled = rows.filter { $0.state != .paused }
        guard !enabled.isEmpty else {
            return BackupsScreenStatus(
                line: everythingPausedLine, detail: everythingPausedDetail,
                targetId: nil, isHealthy: false)
        }
        let worst =
            enabled.min { left, right in
                if left.state.rank != right.state.rank {
                    return left.state.rank < right.state.rank
                }
                return left.targetId < right.targetId
            } ?? enabled[0]
        guard worst.state == .current else {
            return BackupsScreenStatus(
                line: screenText("Check %@", worst.title), detail: worst.stateLine,
                targetId: worst.targetId, isHealthy: false)
        }
        if let late = Staleness.worstGame(of: games) {
            let count = games.count
            let label = rows.first { $0.targetId == late.targetId }?.title
            return BackupsScreenStatus(
                line: count == 1
                    ? screenText("1 game not backed up") : screenText("%lld games not backed up", count),
                detail: late.cause.line(targetLabel: label),
                targetId: late.targetId, isHealthy: false)
        }
        let backedUp = Set(targets.filter { $0.lastSuccessText != nil }.map(\.descriptor.id))
        let notYet = enabled.filter { !backedUp.contains($0.targetId) }
        guard notYet.isEmpty, let lastSuccessText else {
            let detail =
                notYet.count == 1 && enabled.count > 1
                ? screenText("No backup yet at %@", notYet[0].title) : screenText("No backup yet")
            return BackupsScreenStatus(
                line: readyLine, detail: detail, targetId: nil, isHealthy: true)
        }
        return BackupsScreenStatus(
            line: healthyLine, detail: screenText("Last backup %@", lastSuccessText),
            targetId: nil, isHealthy: true)
    }
}
