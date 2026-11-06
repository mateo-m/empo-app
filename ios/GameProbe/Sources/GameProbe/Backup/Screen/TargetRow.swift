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
        }
    }

    public var needsPlus: Bool { self != .iCloudDrive }
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
    /// No Apple Account is signed in on this device.
    case signedOut
    /// iCloud Drive is off on this device or for Empo.
    case iCloudDriveOff
    /// A sideloaded build never holds the entitlement.
    case notInThisBuild
}

/// The one state a target row shows, per SPEC 13.5.
///
/// Several can be true at once. The row shows the one that explains
/// why nothing is moving, and `rank` fixes that order.
public enum TargetRowState: Equatable, Sendable {
    case cannotOpen(TargetReach)
    case placeholder
    case needsPlus
    case paused
    case needsSignIn
    case blockedByPermissions(reason: String)
    case rejected(message: String)
    case full(reason: String)
    case unreachable(at: Date, cause: UnreachableCause = .noAnswer)
    case current

    /// 1 wins over 10.
    public var rank: Int {
        switch self {
        case .cannotOpen: return 1
        case .placeholder: return 2
        case .paused: return 3
        case .needsSignIn: return 4
        case .blockedByPermissions: return 5
        case .needsPlus: return 6
        case .rejected: return 7
        case .full: return 8
        case .unreachable: return 9
        case .current: return 10
        }
    }

    /// Whether the line under the name draws as a problem the user
    /// has to fix.
    public var isProblem: Bool {
        switch self {
        case .needsSignIn, .blockedByPermissions, .rejected, .full, .unreachable: return true
        case .cannotOpen, .placeholder, .needsPlus, .paused, .current: return false
        }
    }
}

/// The button on the right of a target row, where one exists.
public enum TargetRowAction: String, Equatable, Sendable {
    case signIn
    case resume
    /// Backs up now, after the user made space or the server came
    /// back.
    case tryAgain
    case getPlus

    public var label: String {
        switch self {
        case .signIn: return "Sign in"
        case .resume: return "Resume"
        case .tryAgain: return "Try again"
        case .getPlus: return "Get Plus"
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
    /// The failure time in the words the caller formatted, such as
    /// "at 14:03" or "yesterday at 14:03".
    public var failedAtText: String
    /// False for a foreground-only target, per 8.9.
    public var supportsBackgroundTransfer: Bool
    /// How long ago the last run closed a snapshot here, in words
    /// the caller formatted, such as "2 minutes ago".
    public var lastSuccessText: String?
    public var hasPlus: Bool

    public init(
        descriptor: TargetDescriptor,
        reach: TargetReach = .open,
        failure: TargetFailure? = nil,
        failedAt: Date? = nil,
        failedAtText: String = "",
        supportsBackgroundTransfer: Bool = true,
        lastSuccessText: String? = nil,
        hasPlus: Bool = true
    ) {
        self.descriptor = descriptor
        self.reach = reach
        self.failure = failure
        self.failedAt = failedAt
        self.failedAtText = failedAtText
        self.supportsBackgroundTransfer = supportsBackgroundTransfer
        self.lastSuccessText = lastSuccessText
        self.hasPlus = hasPlus
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
    /// Whether the row draws greyed. It still opens, so the user can
    /// remove the location.
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
    public static let iCloudOffLine = "iCloud Drive is off on this device"
    public static let iCloudSignedOutLine = "Not signed in to iCloud on this device"

    /// The one state the row shows.
    public static func state(of facts: TargetRowFacts) -> TargetRowState {
        switch facts.reach {
        case .signedOut, .iCloudDriveOff, .notInThisBuild:
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
        case _ where facts.descriptor.provider.needsPlus && !facts.hasPlus:
            // A restore needs a working sign-in, so the sign-in states
            // above outrank this one.
            return .needsPlus
        case .rejected(let message):
            return .rejected(message: message)
        case .full(let reason):
            return .full(reason: reason)
        case .unreachable(let cause):
            return .unreachable(at: facts.failedAt ?? Date(timeIntervalSince1970: 0), cause: cause)
        case nil:
            return .current
        }
    }

    /// The second line of the row. The row already names the target,
    /// so no line repeats it.
    ///
    /// `time` is the failure time in the words the caller formatted,
    /// such as "at 14:03". The unreachable line reads as a past event,
    /// because the screen holds no connection.
    public static func stateLine(
        _ state: TargetRowState, target: TargetDescriptor, time: String = "",
        lastSuccessText: String? = nil
    ) -> String {
        switch state {
        case .cannotOpen(.signedOut):
            return iCloudSignedOutLine
        case .cannotOpen(.iCloudDriveOff):
            return iCloudOffLine
        case .cannotOpen:
            return "This version of Empo can't use \(target.provider.serviceName)."
        case .placeholder:
            return "Sign in on this device to start"
        case .needsPlus:
            return "Backups stopped. You can still restore."
        case .paused:
            return "Paused"
        case .needsSignIn:
            return "Sign in again to continue"
        case .blockedByPermissions(let reason), .full(let reason):
            return reason
        case .rejected(let message):
            return message
        case .unreachable(_, .noAnswer):
            return "Couldn't connect \(time)"
        case .unreachable(_, .serverError):
            return "Server error \(time)"
        case .unreachable(_, .busy):
            return "Server busy \(time)"
        case .current:
            guard let lastSuccessText else { return "No backup yet" }
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
        case .needsPlus:
            return .getPlus
        case .paused:
            return .resume
        case .full, .unreachable, .rejected:
            return .tryAgain
        case .cannotOpen, .current:
            return nil
        }
    }

    /// The whole row.
    public static func row(_ facts: TargetRowFacts) -> TargetRow {
        let state = state(of: facts)
        return TargetRow(
            targetId: facts.descriptor.id,
            title: facts.descriptor.displayName,
            accountHint: facts.descriptor.accountHint,
            state: state,
            stateLine: stateLine(
                state, target: facts.descriptor, time: facts.failedAtText,
                lastSuccessText: facts.lastSuccessText),
            action: action(for: state),
            foregroundOnlyLine: facts.supportsBackgroundTransfer ? nil : foregroundOnlyLine,
            isDisabled: state.rank == 1)
    }
}
