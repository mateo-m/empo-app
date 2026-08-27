import Foundation

/// The device's heat, as SPEC 7.5 reads it.
///
/// It mirrors `ProcessInfo.ThermalState`, which Foundation gives on
/// Apple platforms only. The rules stay here so `swift test` reaches
/// them on any host, and the app maps the system value onto this
/// one.
public enum DeviceThermalState: Int, Comparable, Codable, CaseIterable, Equatable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (left: DeviceThermalState, right: DeviceThermalState) -> Bool {
        left.rawValue < right.rawValue
    }
}

/// What the device and the app are doing right now.
public struct BackupConditions: Equatable, Sendable {

    /// A play session is live. A paused session still counts as
    /// live, per 7.6, because a background pause keeps the player
    /// view mounted.
    public var isSessionLive: Bool
    public var isLowPowerMode: Bool
    public var thermalState: DeviceThermalState
    /// The user pressed "Back up now".
    public var isManual: Bool

    public init(
        isSessionLive: Bool = false,
        isLowPowerMode: Bool = false,
        thermalState: DeviceThermalState = .nominal,
        isManual: Bool = false
    ) {
        self.isSessionLive = isSessionLive
        self.isLowPowerMode = isLowPowerMode
        self.thermalState = thermalState
        self.isManual = isManual
    }
}

/// Whether staging may run: hashing, compressing, and manifest
/// writes.
public enum StagingGate: Equatable, Sendable {
    case run
    case pause(StagingPause)
}

/// Why staging stopped. The status line says which.
public enum StagingPause: String, Equatable, CaseIterable, Sendable {
    /// Invariant 5. The engine shares Empo's process, so this is a
    /// hard stop and not a QoS demotion.
    case gameRunning = "game-running"
    case lowPowerMode = "low-power-mode"
    case heat

    public var line: String {
        switch self {
        case .gameRunning: return "a game is running"
        case .lowPowerMode: return "Low Power Mode is on"
        case .heat: return "the device is too warm"
        }
    }
}

/// The one app-wide network switch of SPEC 7.4, wired to the two
/// `URLSessionConfiguration` flags it maps onto.
public struct NetworkPolicy: Equatable, Sendable {

    /// "Back up over cellular", off by default. There is no
    /// per-target override.
    public var backsUpOverCellular: Bool

    public init(backsUpOverCellular: Bool = false) {
        self.backsUpOverCellular = backsUpOverCellular
    }

    /// `allowsExpensiveNetworkAccess`. Cellular is the expensive
    /// axis, so Wi-Fi only is this flag set false.
    public var allowsExpensiveNetworkAccess: Bool {
        backsUpOverCellular
    }

    /// `allowsConstrainedNetworkAccess`. Low Data Mode is always
    /// respected and has no toggle, because Apple names that axis as
    /// the one the user already controls. The manual button does not
    /// bypass it.
    public var allowsConstrainedNetworkAccess: Bool {
        false
    }
}

/// The resource rules of SPEC 7.4, 7.5, and 7.6.
public enum ResourcePolicy {

    /// The line the UI shows while the system holds the tasks, per
    /// 7.4. It reads the wait from task state, and nothing re-asks
    /// and nothing fails.
    public static let waitingForWiFiLine = "Waiting for Wi-Fi"

    /// Whether staging may run now.
    ///
    /// A running game wins everything and the manual button does not
    /// bypass it. Low Power Mode stops staging, and the manual
    /// button does bypass that one. Heat has no bypass.
    public static func stagingGate(_ conditions: BackupConditions) -> StagingGate {
        if conditions.isSessionLive { return .pause(.gameRunning) }
        if conditions.isLowPowerMode, !conditions.isManual { return .pause(.lowPowerMode) }
        if conditions.thermalState >= .serious { return .pause(.heat) }
        return .run
    }

    /// Whether a paused run may start staging again.
    ///
    /// Heat resumes at `.fair` or lower, per 7.5, so the pause and
    /// the resume do not share one mark. That gap keeps a device
    /// sitting on the line from starting and stopping every second.
    public static func resumesStagingAfterHeat(_ state: DeviceThermalState) -> Bool {
        state <= .fair
    }

    /// Whether the transfer daemon keeps the uploads it already
    /// holds.
    ///
    /// Yes, under every condition of 7.5. They live in the
    /// background session, and stopping them throws away bytes
    /// already spent. A user pause is the one thing that cancels
    /// them, and a user pause cancels the whole run, per 6.5.
    public static func keepsUploadsInFlight(_ conditions: BackupConditions) -> Bool {
        true
    }

    /// Whether the run asks about cellular before it starts.
    ///
    /// A manual run on cellular asks once, states the size, and does
    /// not change the stored setting. The ask covers the whole run,
    /// later games in the queue included. An automatic run never
    /// asks: it waits, and the stale line reads "waiting for Wi-Fi".
    public static func asksAboutCellular(
        policy: NetworkPolicy, isManual: Bool, isOnCellular: Bool, alreadyAskedThisRun: Bool
    ) -> Bool {
        guard isManual, isOnCellular, !policy.backsUpOverCellular else { return false }
        return !alreadyAskedThisRun
    }

    /// The cause a game carries while the network policy holds the
    /// run, per 7.1. The clock runs anyway.
    public static func blockedCause(
        policy: NetworkPolicy, isOnCellular: Bool
    ) -> StaleCause? {
        guard isOnCellular, !policy.backsUpOverCellular else { return nil }
        return .waitingForWiFi
    }
}
