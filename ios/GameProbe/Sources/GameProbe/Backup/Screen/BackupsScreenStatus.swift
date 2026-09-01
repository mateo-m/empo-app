import Foundation

/// The line at the top of the Backups screen, per SPEC 13.4.
///
/// It answers the only question most visits ask, in the
/// worst-enabled-target voice of 7.1.
public struct BackupsScreenStatus: Equatable, Sendable {

    public var line: String
    /// The target the line names, or `nil` where nothing is wrong.
    public var targetId: String?
    public var isHealthy: Bool

    public init(line: String, targetId: String?, isHealthy: Bool) {
        self.line = line
        self.targetId = targetId
        self.isHealthy = isHealthy
    }
}

public enum BackupsScreenStatusRules {

    public static let everythingPausedLine = "Every backup target is paused"

    /// The status line, or `nil` where no target exists. A screen
    /// with no target shows the empty state of 13.14 instead.
    ///
    /// A paused target leaves the computation, because it left the
    /// promise of 7.1. Two targets in the same state break the tie
    /// on the target id, so the line names the same one on every
    /// refresh.
    ///
    /// `lastSuccessText` carries the newest run across the targets
    /// in the words the caller formatted, such as "today".
    public static func status(
        of targets: [TargetRowFacts], lastSuccessText: String? = nil
    ) -> BackupsScreenStatus? {
        guard !targets.isEmpty else { return nil }
        let rows = targets.map(TargetRowRules.row)
        let enabled = rows.filter { $0.state != .paused }
        guard !enabled.isEmpty else {
            return BackupsScreenStatus(
                line: everythingPausedLine, targetId: nil, isHealthy: false)
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
                line: worst.stateLine, targetId: worst.targetId, isHealthy: false)
        }
        let when = lastSuccessText.map { " \($0)" } ?? ""
        return BackupsScreenStatus(
            line: "All games backed up\(when)", targetId: nil, isHealthy: true)
    }
}
