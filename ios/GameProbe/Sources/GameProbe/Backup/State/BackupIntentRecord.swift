import Foundation

/// The intents of SPEC 6.5. Each is one row, and each survives a
/// process death.
public enum BackupIntentKind: String, Codable, Sendable, CaseIterable, Equatable {
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

    /// What the interrupted work had done.
    public enum Work: Equatable, Sendable {
        /// `uploadedBytes` reached the target. `remainingBytes` is
        /// what the frozen run plan of 13.2 still had to upload, and
        /// the resume question of 13.18 names it.
        case run(uploadedBytes: Int64, remainingBytes: Int64)
        /// A resume takes the same action, so it never widens what
        /// the user chose, per 11.7. `movedAsideTree` is the folder
        /// name that `Game/` took, so a resume does not move the
        /// half-restored tree aside again.
        case restore(RestoreChoice, movedAsideTree: String?)
    }

    public var targetId: String
    /// The game the run or the restore was on. The preferences stream
    /// of 5.3 has no game, so this is `nil` there.
    public var gameKey: String?
    public var snapshotId: String?
    public var work: Work
    public var createdAt: Date
    /// The user already saw the question for this record. The same
    /// interruption never asks twice, per 6.5.
    public var asked: Bool

    public init(
        targetId: String,
        gameKey: String? = nil,
        snapshotId: String? = nil,
        work: Work,
        createdAt: Date,
        asked: Bool = false
    ) {
        self.targetId = targetId
        self.gameKey = gameKey
        self.snapshotId = snapshotId
        self.work = work
        self.createdAt = createdAt
        self.asked = asked
    }

    public var kind: BackupIntentKind {
        switch work {
        case .run: return .interruptedRun
        case .restore: return .interruptedRestore
        }
    }

    /// Whether the next launch shows the question for this record.
    public var asksAtNextLaunch: Bool {
        if asked { return false }
        switch work {
        case .run(let uploadedBytes, _):
            return uploadedBytes >= Self.resumeQuestionFloorBytes
        case .restore:
            return true
        }
    }
}
