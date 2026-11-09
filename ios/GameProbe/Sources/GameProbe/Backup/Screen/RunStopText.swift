import Foundation

/// The run history and the progress pill each name a stop. Their lines differ in the subject, and
/// each one has its own translations.
extension BackupRunStop {

    public var historyLine: String {
        switch self {
        case .writerConflict:
            return BackupNotificationRule.writerSplitLine
        case .readOnlyFormat:
            return screenText("This backup needs a newer version of Empo.")
        case .needsSignIn:
            return screenText("Sign in to this location again.")
        case .blocked(let reason), .full(let reason):
            return reason
        case .quotaShortfall(let shortfall):
            return QuotaCheck.blockedLine(shortfall)
        case .offline:
            return screenText("Empo couldn't connect to this location.")
        case .serverError:
            return screenText("This location had a server error.")
        case .throttled(let retryAfter):
            return screenText("This location asked Empo to wait %lld seconds.", Int(retryAfter))
        case .rejected(let message):
            return message
        case .gameStarted:
            return screenText("A game started. Empo backs up the rest when you stop playing.")
        case .paused:
            return screenText("You or iOS paused the backup.")
        }
    }
}

extension ProgressPill {

    /// The stop reason for a stop that no stale cause names, or
    /// `nil` where the pill can only say that the target did not
    /// finish.
    public static func stopReason(of stop: BackupRunStop, targetLabel: String) -> String? {
        switch stop {
        case .offline:
            return screenText("Empo couldn't connect to %@.", targetLabel)
        case .serverError:
            return screenText("%@ had a server error.", targetLabel)
        case .throttled:
            return screenText("%@ asked Empo to wait.", targetLabel)
        case .readOnlyFormat(.newerFormatVersion):
            return screenText("%@ needs a newer version of Empo.", targetLabel)
        case .readOnlyFormat(.unreadableFormat), .needsSignIn, .blocked, .full, .quotaShortfall, .rejected,
            .writerConflict,
            .gameStarted, .paused:
            return nil
        }
    }
}
