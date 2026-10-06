import Foundation

/// What one provider error does to the target, per SPEC 8.4.
///
/// One error kind has one effect. The effect lives on the error and
/// not in each provider, so a provider cannot invent a new one.
///
/// Nothing here notifies. Section 7.11 decides which failures reach
/// the user.
public enum TargetEffect: Equatable, Sendable {
    /// The target enters needs-sign-in. Runs stop.
    case needsSignIn
    /// The prune ladder of 5.14 runs. If it frees too little, the
    /// target is blocked.
    case runPruneLadder
    /// Wait for the stated time and keep the run.
    case waitAndKeepRun(seconds: TimeInterval)
    /// Silent. Retry on the next pass.
    case retryOnNextPass
    /// The target is blocked. A re-sign-in does not fix a revoked
    /// scope.
    case blocked
    /// The local cache drops the object. The next run uploads it
    /// again.
    case dropFromCache
    /// Permanent. The message shows on the target screen word for
    /// word. The run stops.
    case stopAndShow(message: String)

    /// Whether the run stops now.
    ///
    /// `runPruneLadder` is false because the ladder decides. A prune
    /// that frees enough keeps the run, and one that does not blocks
    /// the target, per 5.14.
    public var stopsTheRun: Bool {
        switch self {
        case .needsSignIn, .blocked, .stopAndShow:
            return true
        case .runPruneLadder, .waitAndKeepRun, .retryOnNextPass, .dropFromCache:
            return false
        }
    }
}

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
    /// The credentials work, but the scope or the folder rights do
    /// not cover the operation.
    case permissionDenied
    /// The target holds no object at that path.
    case notFound
    /// The service refused the request and gave a reason. The
    /// message reaches the user as it is, per 8.4 and 13.7.
    case rejected(message: String)

    /// The one effect of 8.4.
    public var effect: TargetEffect {
        switch self {
        case .authExpired:
            return .needsSignIn
        case .outOfSpace:
            return .runPruneLadder
        case .throttled(let retryAfter):
            return .waitAndKeepRun(seconds: retryAfter)
        case .offline:
            return .retryOnNextPass
        case .permissionDenied:
            return .blocked
        case .notFound:
            return .dropFromCache
        case .rejected(let message):
            return .stopAndShow(message: message)
        }
    }
}
