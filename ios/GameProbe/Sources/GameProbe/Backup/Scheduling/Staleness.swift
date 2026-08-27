import Foundation

/// How far one game is past the promise of SPEC 7.1.
public enum StalenessLevel: Int, Comparable, Codable, CaseIterable, Equatable, Sendable {
    /// Inside the promise. No badge and no line.
    case fresh = 0
    /// Past 7 days. The card badge marks the game and the Backup
    /// sheet carries the cause line.
    case stale = 1
    /// Past 21 days. The library shows one banner, not one per game.
    case banner = 2

    public static func < (left: StalenessLevel, right: StalenessLevel) -> Bool {
        left.rawValue < right.rawValue
    }
}

/// Why a game is late. The stale line names it in plain words, per
/// 7.1, and the banner carries the single action that fixes it.
public enum StaleCause: Equatable, Sendable {
    /// Empo's own policy blocks the run. The clock runs anyway, per
    /// 7.1, because three weeks on cellular leaves the data as
    /// unprotected as a dead token does.
    case waitingForWiFi
    case needsSignIn
    /// Quota or cap reached after the prune ladder of 5.14 ran out.
    case targetBlocked
    case deviceStorageLow
    /// The same save member came back partial on three consecutive
    /// runs, per 7.2.
    case savesPartial(path: String)
    /// Three runs in a row died with the process, per 7.10.
    case runsInterrupted
    /// Nothing is wrong. The run has not come round yet.
    case waitingForARun

    /// The line the Backup sheet and the banner show. Tickets 016,
    /// 017, and 018 render it.
    public func line(targetLabel: String?, deviceName: String = "This device") -> String {
        let target = targetLabel ?? "the backup target"
        switch self {
        case .waitingForWiFi:
            return "waiting for Wi-Fi"
        case .needsSignIn:
            return "\(target) needs you to sign in again"
        case .targetBlocked:
            return "\(target) is full"
        case .deviceStorageLow:
            return "\(deviceName) is low on storage"
        case .savesPartial(let path):
            return "one save file did not copy: \(path)"
        case .runsInterrupted:
            return ForceQuitRule.habitLine
        case .waitingForARun:
            return "waiting for the next backup"
        }
    }

    /// The one action the 21-day banner carries, per 7.1.
    public var action: StaleAction {
        switch self {
        case .waitingForWiFi: return .allowThisRunOverCellular
        case .needsSignIn: return .signInAgain
        case .targetBlocked: return .makeSpaceOnTheTarget
        case .deviceStorageLow: return .freeSpaceOnThisDevice
        case .savesPartial, .runsInterrupted, .waitingForARun: return .backUpNow
        }
    }
}

/// The single action the 21-day banner offers.
public enum StaleAction: String, Equatable, Sendable {
    case allowThisRunOverCellular
    case signInAgain
    case makeSpaceOnTheTarget
    case freeSpaceOnThisDevice
    case backUpNow

    public var label: String {
        switch self {
        case .allowThisRunOverCellular: return "Back up now over cellular"
        case .signInAgain: return "Sign in again"
        case .makeSpaceOnTheTarget: return "Make space"
        case .freeSpaceOnThisDevice: return "Free up space"
        case .backUpNow: return "Back up now"
        }
    }
}

/// One game on one target, with the three values the clock reads.
public struct TargetFreshness: Equatable, Sendable {

    public var targetId: String
    /// A paused target leaves the promise, per 7.1. It never makes a
    /// game stale.
    public var isPaused: Bool
    /// The last run that closed a whole snapshot of this game here.
    public var lastSuccessAt: Date?
    /// When the user last played the game.
    public var lastPlayedAt: Date?
    /// What the line names, when the caller knows it.
    public var cause: StaleCause?

    public init(
        targetId: String,
        isPaused: Bool = false,
        lastSuccessAt: Date? = nil,
        lastPlayedAt: Date? = nil,
        cause: StaleCause? = nil
    ) {
        self.targetId = targetId
        self.isPaused = isPaused
        self.lastSuccessAt = lastSuccessAt
        self.lastPlayedAt = lastPlayedAt
        self.cause = cause
    }
}

/// What one game's badge shows: the worst enabled target, per 7.1.
public struct GameFreshness: Equatable, Sendable {

    public var gameKey: String
    public var level: StalenessLevel
    /// The target the level came from. `nil` when nothing is late.
    public var targetId: String?
    public var cause: StaleCause?
    /// When the game stopped being protected. The clock counts from
    /// here.
    public var unprotectedSince: Date?

    public init(
        gameKey: String = "",
        level: StalenessLevel = .fresh,
        targetId: String? = nil,
        cause: StaleCause? = nil,
        unprotectedSince: Date? = nil
    ) {
        self.gameKey = gameKey
        self.level = level
        self.targetId = targetId
        self.cause = cause
        self.unprotectedSince = unprotectedSince
    }
}

/// The one banner the library shows at 21 days, per 7.1.
public struct LibraryStaleBanner: Equatable, Sendable {

    public var cause: StaleCause
    public var action: StaleAction
    public var targetId: String?
    /// How many games reached the 21-day mark.
    public var gameCount: Int

    public init(cause: StaleCause, action: StaleAction, targetId: String?, gameCount: Int) {
        self.cause = cause
        self.action = action
        self.targetId = targetId
        self.gameCount = gameCount
    }
}

/// The staleness clock of SPEC 7.1.
///
/// The clock only drives warnings. The promise itself is event
/// shaped: after a play session ends, that game's snapshot reaches
/// every enabled target before the next session of that game ends.
/// iOS gives no clock promise, so nothing here schedules a run.
///
/// The clock counts from the last successful snapshot, not from the
/// play, because a user who plays daily and never backs up must
/// still go stale. A game that never had a snapshot counts from its
/// last play, which is the only date this device holds for it.
///
/// The clock runs even when Empo's own policy blocks the run. Three
/// weeks on cellular shows the badge with the line "waiting for
/// Wi-Fi", per 7.1. Empo never overrides its own policy without the
/// user.
///
/// The clock is a parameter. A `Date()` call inside these functions
/// would make the tests unrepeatable.
public enum Staleness {

    /// The card badge appears here, per 7.1.
    public static let staleAfter: TimeInterval = 7 * 86_400
    /// The one library banner appears here.
    public static let bannerAfter: TimeInterval = 21 * 86_400

    /// When one game stopped being protected on one target, or `nil`
    /// where the newest snapshot covers the newest play.
    public static func unprotectedSince(_ target: TargetFreshness) -> Date? {
        guard let played = target.lastPlayedAt else { return nil }
        guard let success = target.lastSuccessAt else { return played }
        return success >= played ? nil : success
    }

    /// How late one game is on one target.
    public static func level(of target: TargetFreshness, now: Date) -> StalenessLevel {
        guard !target.isPaused, let since = unprotectedSince(target) else { return .fresh }
        let age = now.timeIntervalSince(since)
        if age >= bannerAfter { return .banner }
        if age >= staleAfter { return .stale }
        return .fresh
    }

    /// The badge one game's card shows: the worst enabled target.
    ///
    /// A paused target never wins, because it left the promise. Two
    /// targets at the same level break the tie on the older clock,
    /// then on the target id, so the badge names the same target on
    /// every refresh.
    public static func worst(
        gameKey: String = "", of targets: [TargetFreshness], now: Date
    ) -> GameFreshness {
        var worst = GameFreshness(gameKey: gameKey)
        for target in targets where !target.isPaused {
            let level = level(of: target, now: now)
            guard level != .fresh else { continue }
            let since = unprotectedSince(target)
            if level > worst.level || (level == worst.level && wins(since, over: worst, target)) {
                worst = GameFreshness(
                    gameKey: gameKey,
                    level: level,
                    targetId: target.targetId,
                    cause: target.cause ?? .waitingForARun,
                    unprotectedSince: since)
            }
        }
        return worst
    }

    /// The tie-break inside one level: the older clock, then the
    /// target id.
    private static func wins(
        _ since: Date?, over worst: GameFreshness, _ target: TargetFreshness
    ) -> Bool {
        let held = worst.unprotectedSince ?? .distantFuture
        let candidate = since ?? .distantFuture
        if candidate != held { return candidate < held }
        return target.targetId < (worst.targetId ?? "")
    }

    /// The one banner, or `nil` while no game has reached 21 days.
    ///
    /// One banner covers the library, not one per game. It names the
    /// cause of the worst game and carries that cause's action.
    public static func libraryBanner(_ games: [GameFreshness]) -> LibraryStaleBanner? {
        let late = games.filter { $0.level == .banner }
        guard !late.isEmpty else { return nil }
        let worst =
            late.min { left, right in
                let leftSince = left.unprotectedSince ?? .distantFuture
                let rightSince = right.unprotectedSince ?? .distantFuture
                if leftSince != rightSince { return leftSince < rightSince }
                return left.gameKey < right.gameKey
            } ?? late[0]
        let cause = worst.cause ?? .waitingForARun
        return LibraryStaleBanner(
            cause: cause,
            action: cause.action,
            targetId: worst.targetId,
            gameCount: late.count)
    }
}
