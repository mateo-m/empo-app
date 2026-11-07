import Foundation

/// What one row of Backup history shows, per SPEC 13.4.
public enum BackupHistoryState: Equatable, Sendable {
    case backingUp
    case success
    case partial
    case failed
    case cancelled

    /// A row with no end is the run in flight, or a run that did
    /// not write its end.
    public static func of(_ run: BackupRunRecord, liveRunId: String?) -> Self {
        guard let end = run.end else { return run.id == liveRunId ? .backingUp : .failed }
        switch end.outcome {
        case .success: return .success
        case .partial: return .partial
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

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
