import Foundation

/// What one target last failed with. The five cases are row states 4
/// to 8 of SPEC 13.5.
///
/// The row outlives the run that produced it, so the state store
/// keeps the last one, per 6.2.
public enum TargetFailure: Equatable, Sendable {
    case needsSignIn
    case blockedByPermissions(reason: String)
    case rejected(message: String)
    case full(reason: String)
    case unreachable

    /// The failure a run stop leaves on the target, or `nil` where
    /// the stop says nothing about the target itself.
    public static func of(_ stop: BackupRunStop) -> TargetFailure? {
        switch stop {
        case .needsSignIn:
            return .needsSignIn
        case .blocked(let reason):
            return .blockedByPermissions(reason: reason)
        case .full(let reason):
            return .full(reason: reason)
        case .quotaShortfall(let shortfall):
            return .full(reason: QuotaCheck.blockedLine(shortfall))
        case .offline, .throttled:
            return .unreachable
        case .rejected(let message):
            return .rejected(message: message)
        case .writerConflict, .readOnlyFormat:
            // A split keeps backing up, per 5.12, and a read-only
            // format needs a newer Empo, not an action on the row.
            return nil
        }
    }
}

extension TargetFailure {

    /// The two columns `target_status` holds, per SPEC 6.2.
    public var kind: String {
        switch self {
        case .needsSignIn: return "needs-sign-in"
        case .blockedByPermissions: return "blocked"
        case .rejected: return "rejected"
        case .full: return "full"
        case .unreachable: return "unreachable"
        }
    }

    public var detail: String {
        switch self {
        case .blockedByPermissions(let reason), .full(let reason):
            return reason
        case .rejected(let message):
            return message
        case .needsSignIn, .unreachable:
            return ""
        }
    }

    public init?(kind: String?, detail: String) {
        switch kind {
        case "needs-sign-in": self = .needsSignIn
        case "blocked": self = .blockedByPermissions(reason: detail)
        case "rejected": self = .rejected(message: detail)
        case "full": self = .full(reason: detail)
        case "unreachable": self = .unreachable
        default: return nil
        }
    }
}
