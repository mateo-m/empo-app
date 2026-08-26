import Foundation

/// The three intents of SPEC 6.5. Each is one row, and each survives
/// a process death.
public enum BackupIntentKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// The user paused a run. The outstanding upload tasks are
    /// cancelled and the staging and outbox files stay. Resume is one
    /// tap while the process lives, so a pause never asks at launch.
    case pausedRun = "paused-run"
    /// A run died with the process. Under the 100 MB floor Empo
    /// recovers silently. Over it, the next launch asks once.
    case interruptedRun = "interrupted-run"
    /// A restore did not finish. The next launch asks once, whatever
    /// the size, because a half-restored game is not a state to leave
    /// quietly.
    case interruptedRestore = "interrupted-restore"
}

/// One intent record, per SPEC 6.5.
public struct BackupIntentRecord: Equatable, Sendable {

    /// The floor that decides whether an interrupted run asks at the
    /// next launch, per 6.5.
    public static let resumeQuestionFloorBytes: Int64 = 100 * 1024 * 1024

    public var kind: BackupIntentKind
    public var targetId: String
    /// The game the run or the restore was on. The preferences stream
    /// of 5.3 has no game, so this is `nil` there.
    public var gameKey: String?
    public var snapshotId: String?
    /// What reached the target before the interruption.
    public var uploadedBytes: Int64
    public var createdAt: Date
    /// The user already saw the question for this record. The same
    /// interruption never asks twice, per 6.5.
    public var asked: Bool

    public init(
        kind: BackupIntentKind,
        targetId: String,
        gameKey: String? = nil,
        snapshotId: String? = nil,
        uploadedBytes: Int64 = 0,
        createdAt: Date,
        asked: Bool = false
    ) {
        self.kind = kind
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.uploadedBytes = uploadedBytes
        self.createdAt = createdAt
        self.asked = asked
    }

    /// Whether the next launch shows the question for this record.
    /// Ticket 018 builds the sheet.
    public var asksAtNextLaunch: Bool {
        if asked { return false }
        switch kind {
        case .pausedRun:
            return false
        case .interruptedRun:
            return uploadedBytes >= Self.resumeQuestionFloorBytes
        case .interruptedRestore:
            return true
        }
    }
}
