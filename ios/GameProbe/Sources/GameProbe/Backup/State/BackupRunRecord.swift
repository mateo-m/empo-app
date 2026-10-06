import Foundation

/// How a run ended, per SPEC 6.6 and 7.11.
public enum BackupRunOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    case success
    /// Every game the run covered stopped short of a full snapshot,
    /// per 5.9 and 7.2.
    case partial
    /// The run failed. This row is the only written record of a
    /// transient failure, which is what makes the quiet-failure rule
    /// of 7.11 safe.
    case failed
    /// The user paused or the policy stopped the run.
    case cancelled
}

/// One row of the run history of SPEC 6.6.
///
/// There is one global list. No per-target list and no per-game list,
/// because both would be the same data filtered.
public struct BackupRunRecord: Equatable, Sendable {

    /// How long a row stays, per 6.6.
    public static let retention: TimeInterval = 90 * 86_400

    public var id: String
    public var targetId: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: BackupRunOutcome
    public var uploadedBytes: Int64
    /// How many games the run covered.
    public var gameCount: Int
    /// The failure line, when there is one. The screens of section 13
    /// show it.
    public var detail: String?

    public init(
        id: String,
        targetId: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        outcome: BackupRunOutcome,
        uploadedBytes: Int64 = 0,
        gameCount: Int = 0,
        detail: String? = nil
    ) {
        self.id = id
        self.targetId = targetId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.uploadedBytes = uploadedBytes
        self.gameCount = gameCount
        self.detail = detail
    }
}
