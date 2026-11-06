import Foundation

/// What one row of Backup history shows, per SPEC 13.4.
public enum BackupHistoryState: Equatable, Sendable {
    case backingUp
    case success
    case partial
    case failed
    case cancelled

    /// The engine writes the row before the first byte moves, so a
    /// row with no finish time is either the run in flight or a run
    /// that the process did not live to finish.
    public static func of(_ run: BackupRunRecord, passStartedAt: Date?) -> Self {
        if run.finishedAt == nil, let passStartedAt, run.startedAt >= passStartedAt {
            return .backingUp
        }
        switch run.outcome {
        case .success: return .success
        case .partial: return .partial
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    public static let unfinishedLine = screenText("Empo closed before this backup finished.")

    public var title: String {
        switch self {
        case .backingUp: return screenText("Backing up…")
        case .success: return screenText("Backed up")
        case .partial: return screenText("Partly backed up")
        case .failed: return screenText("Didn't finish")
        case .cancelled: return screenText("Stopped")
        }
    }
}
