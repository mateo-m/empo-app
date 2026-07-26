import Foundation

/// The pure decision core of cross-session play. Every gate and
/// routing choice - can this game launch, does a clean exit drop
/// straight to the library, how is an end-of-session alert framed -
/// lives here as side-effect-free functions over plain values, so
/// `EmpoTests` can drive the full truth table without the engine
/// bridge. `CrossSessionPlay`, `AppState`, and `RootView` supply the
/// live inputs (bridge calls, memory readings) and act on the
/// answers.
///
/// Ordering contracts encoded here (and pinned by tests):
/// - The hung-engine check short-circuits BEFORE the capability
///   query: a hung engine never terminates, so capability would
///   wrongly predict FRESH - and the caller must not reach
///   `mkxp_setGamePath`, which would erase the hung flag.
/// - The memory gate runs last and only when requested: the
///   quit-and-play flow measures while the quit game is still
///   resident and must skip it.
/// - "Recoverable" (terminated + not hung + no stuck Ruby instance)
///   decides library-return vs. force-close framing everywhere; a
///   crash that strands its instance must never get the friendly
///   path, or the user lands in a library where every tap is
///   blocked.
enum CrossSessionPolicy {

    /// Mirrors the engine's MKXPSessionCapability.
    enum Capability: Equatable {
        case fresh
        case dirty
        case unavailable
    }

    enum Blocker: Equatable {
        case dirtyRuby
        case engineHung
        case lowMemory
    }

    /// Why a launch must be refused, or nil when it is safe.
    /// `capability` and `availableMemoryBytes` are closures so the
    /// short-circuit order is part of the contract: neither runs for
    /// the first session of a launch, and neither runs when the
    /// engine is hung.
    static func launchBlocker(
        enabled: Bool,
        sessionsStarted: Int,
        engineHung: Bool,
        includeMemoryGate: Bool,
        minimumBytesForNextSession: Int,
        capability: () -> Capability,
        availableMemoryBytes: () -> Int
    ) -> Blocker? {
        guard enabled, sessionsStarted > 0 else { return nil }
        if engineHung {
            return .engineHung
        }
        if capability() != .fresh {
            return .dirtyRuby
        }
        if includeMemoryGate, availableMemoryBytes() < minimumBytesForNextSession {
            return .lowMemory
        }
        return nil
    }

    /// A clean engine exit drops straight back to the library only
    /// when no alert is in flight (a boot-gate parting message
    /// already presents one; tearing the phase down under a
    /// presented alert makes SwiftUI swallow the NavigationStack
    /// pop) and the session ended recoverably (a failed VM quiesce
    /// leaves the instance stuck, and the library would be a
    /// dead end).
    static func cleanExitReturnsToLibrary(
        enabled: Bool,
        errorAlertActive: Bool,
        recoverable: Bool
    ) -> Bool {
        enabled && !errorAlertActive && recoverable
    }

    /// Whether the alert OK button may tear the ended session down
    /// to the library. Mid-game errors (engine still running, not
    /// recoverable-terminated) must keep the session up.
    static func canFinishEndedSession(
        enabled: Bool,
        phaseActive: Bool,
        recoverable: Bool
    ) -> Bool {
        enabled && phaseActive && recoverable
    }

    /// True when an error alert presents over a session whose engine
    /// terminated recoverably - the OK button then returns to the
    /// library, so the message must not tell the user to force-close.
    static func sessionEndedBehindAlert(
        enabled: Bool,
        recoverable: Bool
    ) -> Bool {
        enabled && recoverable
    }

    static func errorAlertTitle(
        engineHung: Bool,
        phaseActive: Bool,
        sessionEndedBehindAlert: Bool,
        cleanExit: Bool
    ) -> String {
        if engineHung { return "Restart Empo" }
        if phaseActive {
            guard sessionEndedBehindAlert else { return "Restart Empo" }
            // Recoverable, but distinguish a game that chose to end
            // (clean exit, parting message) from one that failed
            // before Ruby ran (load error, retired instance).
            return cleanExit ? "Game ended" : "Something went wrong"
        }
        return "Something went wrong"
    }

    /// Whether the alert body appends "Close Empo from the app
    /// switcher and reopen it to continue."
    static func appendsForceCloseGuidance(
        engineHung: Bool,
        phaseActive: Bool,
        sessionEndedBehindAlert: Bool
    ) -> Bool {
        // The hung branch carries its own dedicated message.
        !engineHung && phaseActive && !sessionEndedBehindAlert
    }
}
