import Foundation

/// The three causes that fail fast, per SPEC 7.11.
///
/// Everything else is transient. It waits for the next run and feeds
/// only the stale line: network drops, throttling, single-file
/// errors, Low Power Mode pauses, and thermal pauses.
public enum BackupFailFastCause: String, Codable, CaseIterable, Equatable, Sendable {
    case signInDead = "sign-in-dead"
    /// Quota or cap reached after the prune ladder of 5.14 ran out.
    case targetBlocked = "target-blocked"
    /// Device storage below the floor of 6.4.
    case deviceStorageLow = "device-storage-low"

    public var staleCause: StaleCause {
        switch self {
        case .signInDead: return .needsSignIn
        case .targetBlocked: return .targetBlocked
        case .deviceStorageLow: return .deviceStorageLow
        }
    }
}

/// Which of the three causes a run stop is, and what each one says.
///
/// **Notify only when a problem exists and only user action can
/// clear it.** Exactly the three causes qualify. Progress,
/// completion, staleness warnings, and self-healing pauses stay
/// silent forever.
public enum BackupNotificationRule {

    /// The cause a run stop carries, or `nil` where the stop is
    /// transient.
    public static func failFastCause(of stop: BackupRunStop) -> BackupFailFastCause? {
        switch stop {
        case .needsSignIn:
            return .signInDead
        case .blocked:
            // Rights, not space. A re-sign-in with full access is
            // what fixes it, per 8.4, so the sign-in copy is the
            // one that names the fix.
            return .signInDead
        case .full, .quotaShortfall:
            return .targetBlocked
        case .writerConflict, .readOnlyFormat, .offline, .throttled, .rejected:
            // The writer split is not a failure, per 7.11. Backups
            // keep flowing into the new namespace, so it never
            // notifies. The others wait for the next run.
            return nil
        }
    }

    /// The cause a stream outcome carries. Only the local space stop
    /// of rule 6 of 6.4 qualifies.
    public static func failFastCause(of outcome: StreamOutcome) -> BackupFailFastCause? {
        outcome == .notEnoughLocalSpace ? .deviceStorageLow : nil
    }

    /// The copy of 7.11, which is canonical. It states the problem
    /// and the fix.
    public static func text(
        for cause: BackupFailFastCause, targetLabel: String, deviceName: String
    ) -> String {
        switch cause {
        case .signInDead:
            return "Sign in to \(targetLabel) again. Your backups are waiting."
        case .targetBlocked:
            return "\(targetLabel) is full. Make space or raise the cap to continue."
        case .deviceStorageLow:
            return "\(deviceName) storage is low. Free up space to keep backing up."
        }
    }

    /// The line the Backups screen shows after a writer split, per
    /// 7.11 and 5.12. It heals itself, so a notification would
    /// report a problem that is not one.
    public static let writerSplitLine =
        "Another device was using this backup location. New snapshots go to a new space, "
        + "and both keep their history."

    /// Whether to ask for notification permission now.
    ///
    /// Empo asks after the user configures their first target, never
    /// at first launch, per 7.11.
    public static func asksForPermission(configuredTargetCount: Int, hasAsked: Bool) -> Bool {
        !hasAsked && configuredTargetCount >= 1
    }
}

/// Which notifications are armed, per SPEC 7.11.
///
/// Each cause posts one local notification, once. It re-arms only
/// after the blocker clears and returns, so a target that stays dead
/// for a month notifies once and not thirty times.
///
/// The two target causes are keyed by target, because two targets
/// can both lose their sign-in. Low device storage is keyed by the
/// device, because three targets on one full phone are one problem.
public struct BackupNotificationLedger: Equatable, Sendable {

    /// The causes already posted, as `<cause>@<target id>` for a
    /// target cause and `<cause>` alone for the device cause. A key
    /// that leaves the set arms the cause again.
    public private(set) var postedKeys: Set<String>

    public init(postedKeys: Set<String> = []) {
        self.postedKeys = postedKeys
    }

    private static func key(_ cause: BackupFailFastCause, targetId: String) -> String {
        cause == .deviceStorageLow ? cause.rawValue : "\(cause.rawValue)@\(targetId)"
    }

    /// Takes what one run found on one target and returns what to
    /// post now.
    ///
    /// A cause the run no longer reports leaves the ledger, so it
    /// notifies again when it returns.
    public mutating func post(
        causes: Set<BackupFailFastCause>, targetId: String
    ) -> [BackupFailFastCause] {
        var toPost: [BackupFailFastCause] = []
        for cause in BackupFailFastCause.allCases {
            let key = Self.key(cause, targetId: targetId)
            if causes.contains(cause) {
                if !postedKeys.contains(key) {
                    postedKeys.insert(key)
                    toPost.append(cause)
                }
            } else {
                postedKeys.remove(key)
            }
        }
        return toPost
    }
}
