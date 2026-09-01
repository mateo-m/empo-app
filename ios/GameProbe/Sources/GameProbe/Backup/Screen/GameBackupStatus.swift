import Foundation

/// One target's state for one game, as the status line of SPEC 13.16
/// reads it.
public struct GameTargetState: Equatable, Sendable {

    public var targetId: String
    /// The label the user gave the target, per 8.8.
    public var displayName: String
    public var isPaused: Bool
    /// What holds this game back on this target, or `nil` where
    /// nothing does.
    public var cause: StaleCause?
    public var lastSuccessAt: Date?
    /// When the user last played the game. The clock of 7.1 counts
    /// from here where no snapshot covers the play.
    public var lastPlayedAt: Date?

    public init(
        targetId: String,
        displayName: String,
        isPaused: Bool = false,
        cause: StaleCause? = nil,
        lastSuccessAt: Date? = nil,
        lastPlayedAt: Date? = nil
    ) {
        self.targetId = targetId
        self.displayName = displayName
        self.isPaused = isPaused
        self.cause = cause
        self.lastSuccessAt = lastSuccessAt
        self.lastPlayedAt = lastPlayedAt
    }

    /// The clock inputs of 7.1. The status line of 13.16, the card
    /// badge, and the library banner all read one ladder through
    /// this.
    public var freshness: TargetFreshness {
        TargetFreshness(
            targetId: targetId,
            isPaused: isPaused,
            lastSuccessAt: lastSuccessAt,
            lastPlayedAt: lastPlayedAt,
            cause: cause)
    }
}

/// The eight states of SPEC 13.16, highest first.
public enum GameBackupState: Equatable, Sendable {
    case running
    case paused
    case failed(StaleCause)
    /// Empo's own policy holds the run, per 7.4.
    case waitingForWiFi
    case stale(days: Int)
    case healthy
    case neverRun
    case notSetUp

    public var rank: Int {
        switch self {
        case .running: return 1
        case .paused: return 2
        case .failed: return 3
        case .waitingForWiFi: return 4
        case .stale: return 5
        case .healthy: return 6
        case .neverRun: return 7
        case .notSetUp: return 8
        }
    }
}

/// The four badge states of SPEC 13.3, and no more.
///
/// The badge reads this same computation, so the badge and the
/// status line never disagree. Ticket 018 draws it.
public enum GameBackupBadge: Equatable, Sendable {
    case uploading
    case paused
    case failed
    case stale
    /// A game that is backed up and current shows nothing, per
    /// invariant 9.
    case none
}

/// The status line of SPEC 13.16.
public struct GameBackupStatus: Equatable, Sendable {

    public var state: GameBackupState
    /// The target the line names, or `nil` where it names none.
    public var targetLabel: String?

    public init(state: GameBackupState, targetLabel: String? = nil) {
        self.state = state
        self.targetLabel = targetLabel
    }

    /// `lastSuccessText` carries the day in the words the caller
    /// formatted, such as "today" or "on 4 March".
    public func line(lastSuccessText: String? = nil) -> String {
        switch state {
        case .running:
            return "Backing up now"
        case .paused:
            return "Paused"
        case .failed:
            return "Last backup failed"
        case .waitingForWiFi:
            return "Waiting for Wi-Fi"
        case .stale(let days):
            return days == 1 ? "Backed up 1 day ago" : "Backed up \(days) days ago"
        case .healthy:
            let day = lastSuccessText ?? "today"
            return "Backed up \(day)" + (targetLabel.map { " · \($0)" } ?? "")
        case .neverRun:
            return "Never backed up"
        case .notSetUp:
            return "Not set up"
        }
    }

    /// The second line a failure carries, per 13.16.
    public var causeLine: String? {
        guard case .failed(let cause) = state else { return nil }
        return cause.line(targetLabel: targetLabel)
    }

    public var badge: GameBackupBadge {
        switch state {
        case .running: return .uploading
        case .paused: return .paused
        case .failed: return .failed
        case .stale: return .stale
        case .waitingForWiFi, .healthy, .neverRun, .notSetUp: return .none
        }
    }
}

/// The per-game status of SPEC 13.16, in the worst-enabled-target
/// voice of 7.1.
public enum GameBackupStatusRules {

    public static func status(
        targets: [GameTargetState], isRunning: Bool, now: Date
    ) -> GameBackupStatus {
        guard !targets.isEmpty else { return GameBackupStatus(state: .notSetUp) }
        if isRunning { return GameBackupStatus(state: .running) }

        let enabled = targets.filter { !$0.isPaused }
        // A paused target left the promise of 7.1, so it never wins
        // a state. A game whose every target is paused has nobody
        // left to speak for it.
        guard !enabled.isEmpty else { return GameBackupStatus(state: .paused) }

        let failing = enabled.filter { isAFailure($0.cause) }
        if let worst = failing.min(by: order) {
            return GameBackupStatus(
                state: .failed(worst.cause ?? .waitingForARun),
                targetLabel: label(failing))
        }

        let waiting = enabled.filter { $0.cause == .waitingForWiFi }
        if !waiting.isEmpty {
            return GameBackupStatus(state: .waitingForWiFi, targetLabel: label(waiting))
        }

        // The ladder of 7.1 decides who is late, so the line, the
        // card badge, and the library banner never disagree.
        let late = enabled.filter { Staleness.level(of: $0.freshness, now: now) != .fresh }
        let worstId = Staleness.worst(of: late.map(\.freshness), now: now).targetId
        if let worst = late.first(where: { $0.targetId == worstId }) {
            return GameBackupStatus(
                state: .stale(days: days(since: worst.lastSuccessAt, now: now) ?? staleDays),
                targetLabel: label(late))
        }

        guard enabled.contains(where: { $0.lastSuccessAt != nil }) else {
            return GameBackupStatus(state: .neverRun)
        }
        return GameBackupStatus(state: .healthy, targetLabel: label(enabled))
    }

    private static let staleDays = Int(Staleness.staleAfter / 86_400)

    /// A cause that is not the clock and not the policy is a
    /// failure, per 13.16.
    private static func isAFailure(_ cause: StaleCause?) -> Bool {
        switch cause {
        case .none, .waitingForARun, .waitingForWiFi: return false
        default: return true
        }
    }

    /// The line names a target only when exactly one target is at
    /// fault. That keeps "Backed up today · Dropbox" honest and
    /// avoids "Backed up today · 3 targets".
    private static func label(_ targets: [GameTargetState]) -> String? {
        targets.count == 1 ? targets[0].displayName : nil
    }

    /// The failure the line names: the oldest success first, then
    /// the target id, so one set of targets always answers the same
    /// way. A failure is not a staleness level, so the ladder of 7.1
    /// cannot pick it.
    private static func order(_ left: GameTargetState, _ right: GameTargetState) -> Bool {
        let leftAt = left.lastSuccessAt ?? .distantPast
        let rightAt = right.lastSuccessAt ?? .distantPast
        return leftAt == rightAt ? left.targetId < right.targetId : leftAt < rightAt
    }

    private static func days(since date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        return Int(now.timeIntervalSince(date) / 86_400)
    }
}
