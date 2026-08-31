import Foundation

extension BackupProviderKind {

    /// The name the screens use, per SPEC 11.4. No screen says
    /// "provider".
    public var serviceName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .s3: return "S3 storage"
        case .webdav: return "WebDAV server"
        case .sftp: return "SFTP server"
        }
    }
}

extension TargetDescriptor {

    /// What every screen calls this target: the user's own label
    /// where they gave one, and the service name otherwise.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.serviceName : trimmed
    }
}

/// Whether this build and this device can open one target, per SPEC
/// 9.1. Only iCloud Drive answers anything but `open` in v1.
public enum TargetReach: Equatable, Sendable {
    case open
    /// The Apple ID is signed out, or iCloud Drive is off.
    case accountOff
    /// A sideloaded build never holds the entitlement.
    case notInThisBuild
}

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

/// The one state a target row shows, per SPEC 13.5.
///
/// Several can be true at once. The row shows the one that explains
/// why nothing is moving, and `rank` fixes that order.
public enum TargetRowState: Equatable, Sendable {
    case cannotOpen(TargetReach)
    case placeholder
    case paused
    case needsSignIn
    case blockedByPermissions(reason: String)
    case rejected(message: String)
    case full(reason: String)
    case unreachable(at: Date)
    case current

    /// 1 wins over 9.
    public var rank: Int {
        switch self {
        case .cannotOpen: return 1
        case .placeholder: return 2
        case .paused: return 3
        case .needsSignIn: return 4
        case .blockedByPermissions: return 5
        case .rejected: return 6
        case .full: return 7
        case .unreachable: return 8
        case .current: return 9
        }
    }
}

/// The button on the right of a target row, where one exists.
public enum TargetRowAction: String, Equatable, Sendable {
    case signIn
    case resume
    case makeSpace

    public var label: String {
        switch self {
        case .signIn: return "Sign in"
        case .resume: return "Resume"
        case .makeSpace: return StaleAction.makeSpaceOnTheTarget.label
        }
    }
}

/// What the screen knows about one target when it draws its row.
public struct TargetRowFacts: Equatable, Sendable {

    public var descriptor: TargetDescriptor
    public var reach: TargetReach
    public var failure: TargetFailure?
    /// When the failure happened. The unreachable line names it.
    public var failedAt: Date?
    /// False for a foreground-only target, per 8.9.
    public var supportsBackgroundTransfer: Bool
    /// How long ago the last run closed a snapshot here, in words
    /// the caller formatted, such as "2 minutes ago".
    public var lastSuccessText: String?

    public init(
        descriptor: TargetDescriptor,
        reach: TargetReach = .open,
        failure: TargetFailure? = nil,
        failedAt: Date? = nil,
        supportsBackgroundTransfer: Bool = true,
        lastSuccessText: String? = nil
    ) {
        self.descriptor = descriptor
        self.reach = reach
        self.failure = failure
        self.failedAt = failedAt
        self.supportsBackgroundTransfer = supportsBackgroundTransfer
        self.lastSuccessText = lastSuccessText
    }
}

/// One drawn row of the target list, per SPEC 13.5.
public struct TargetRow: Equatable, Sendable {

    public var targetId: String
    /// The first line, left side.
    public var title: String
    /// The first line, right of the title. Two targets on one
    /// service are allowed, so the hint tells them apart.
    public var accountHint: String?
    public var state: TargetRowState
    /// The second line. Exactly one state.
    public var stateLine: String
    public var action: TargetRowAction?
    /// The permanent line of 8.9, under the state line.
    public var foregroundOnlyLine: String?
    /// Whether the row draws greyed and takes no tap.
    public var isDisabled: Bool

    public init(
        targetId: String,
        title: String,
        accountHint: String?,
        state: TargetRowState,
        stateLine: String,
        action: TargetRowAction?,
        foregroundOnlyLine: String?,
        isDisabled: Bool
    ) {
        self.targetId = targetId
        self.title = title
        self.accountHint = accountHint
        self.state = state
        self.stateLine = stateLine
        self.action = action
        self.foregroundOnlyLine = foregroundOnlyLine
        self.isDisabled = isDisabled
    }
}

/// The row rules of SPEC 13.5, as pure functions.
public enum TargetRowRules {

    /// The permanent line a foreground-only target carries, per 8.9.
    public static let foregroundOnlyLine = "Backs up only while Empo is open"

    /// The line an iCloud target shows while the runtime gate of 9.1
    /// answers nil.
    public static let iCloudOffLine = "iCloud is off or not signed in on this device"

    /// The one state the row shows.
    public static func state(of facts: TargetRowFacts) -> TargetRowState {
        switch facts.reach {
        case .accountOff, .notInThisBuild:
            return .cannotOpen(facts.reach)
        case .open:
            break
        }
        if facts.descriptor.isPlaceholder { return .placeholder }
        // Paused outranks needs-sign-in on purpose. Signing in again
        // to a paused target changes nothing the user can see.
        if facts.descriptor.isPaused { return .paused }
        switch facts.failure {
        case .needsSignIn:
            return .needsSignIn
        case .blockedByPermissions(let reason):
            return .blockedByPermissions(reason: reason)
        case .rejected(let message):
            return .rejected(message: message)
        case .full(let reason):
            return .full(reason: reason)
        case .unreachable:
            return .unreachable(at: facts.failedAt ?? Date(timeIntervalSince1970: 0))
        case nil:
            return .current
        }
    }

    /// The second line of the row.
    ///
    /// `time` is the failure time in the words the caller formatted,
    /// such as "14:03". The unreachable line reads as a past event,
    /// because the screen holds no connection.
    public static func stateLine(
        _ state: TargetRowState, target: TargetDescriptor, time: String = "",
        lastSuccessText: String? = nil
    ) -> String {
        switch state {
        case .cannotOpen(.accountOff):
            return iCloudOffLine
        case .cannotOpen:
            return "This build cannot open \(target.provider.serviceName)"
        case .placeholder:
            return "Sign in on this device to use this target"
        case .paused:
            return "Paused"
        case .needsSignIn:
            return StaleCause.needsSignIn.line(targetLabel: target.displayName)
        case .blockedByPermissions(let reason), .full(let reason):
            return reason
        case .rejected(let message):
            return message
        case .unreachable:
            let host = target.accountHint ?? target.displayName
            return "Could not reach \(host) at \(time)"
        case .current:
            guard let lastSuccessText else { return "Up to date" }
            return "Last backup \(lastSuccessText)"
        }
    }

    /// The button the row carries, or `nil` where the user can do
    /// nothing from here.
    ///
    /// A revoked folder right and a dead token look identical from
    /// the row, per 13.7, so both offer the same sign-in.
    public static func action(for state: TargetRowState) -> TargetRowAction? {
        switch state {
        case .placeholder, .needsSignIn, .blockedByPermissions:
            return .signIn
        case .paused:
            return .resume
        case .full:
            return .makeSpace
        case .cannotOpen, .rejected, .unreachable, .current:
            return nil
        }
    }

    /// The whole row.
    public static func row(_ facts: TargetRowFacts, time: String = "") -> TargetRow {
        let state = state(of: facts)
        return TargetRow(
            targetId: facts.descriptor.id,
            title: facts.descriptor.displayName,
            accountHint: facts.descriptor.accountHint,
            state: state,
            stateLine: stateLine(
                state, target: facts.descriptor, time: time,
                lastSuccessText: facts.lastSuccessText),
            action: action(for: state),
            foregroundOnlyLine: facts.supportsBackgroundTransfer ? nil : foregroundOnlyLine,
            isDisabled: state.rank == 1)
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
