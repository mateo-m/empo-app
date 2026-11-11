import Foundation

/// The seven error kinds of SPEC 8.4. Every provider maps its own
/// failures onto these, and the engine sees no other kind.
public enum BackupProviderError: Error, Equatable, Sendable {
    /// The token or the password no longer works.
    case authExpired
    /// The account, the bucket, or the cap has no room left.
    case outOfSpace
    /// The service asked Empo to wait. `retryAfter` is in seconds,
    /// from the provider's own `Retry-After`, per 8.6.
    case throttled(retryAfter: TimeInterval)
    /// The device has no route to the target.
    case offline
    /// The service answered with a 5xx. It may be full, broken, or
    /// down for upkeep, and the answer does not say which.
    case serverError(status: Int)
    /// The credentials work, but the scope or the folder rights do
    /// not cover the operation.
    case permissionDenied
    /// The target holds no object at that path.
    case notFound
    /// The service refused the request and gave a reason. The
    /// message reaches the user as it is, per 8.4 and 13.7.
    case rejected(message: String)

    /// A refusal the screen can show as it is. The status number
    /// stays out, and the server's own words, where it gave some,
    /// follow in quotes.
    static func refusal(by who: String, said: String = "") -> BackupProviderError {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return .rejected(message: screenText("%@ refused the request.", who)) }
        return .rejected(message: screenText("%@ refused the request. It said: “%@”", who, said))
    }

    /// The run stop of 8.4, or `nil` for `permissionDenied`, because only the run knows which
    /// service to name in that line. The engine runs the prune ladder of 5.14 before it stops on
    /// `outOfSpace`.
    public var runStop: BackupRunStop? {
        switch self {
        case .authExpired:
            return .needsSignIn
        case .permissionDenied:
            return nil
        case .rejected(let message):
            return .rejected(message: message)
        case .offline:
            return .offline
        case .serverError(let status):
            return .serverError(status: status)
        case .throttled(let retryAfter):
            return .throttled(retryAfter: retryAfter)
        case .outOfSpace:
            return .full(reason: QuotaCheck.prunedAndStillFullLine)
        case .notFound:
            return .rejected(
                message: screenText(
                    "A backup file is missing from this location. Back up again to replace it."))
        }
    }
}
