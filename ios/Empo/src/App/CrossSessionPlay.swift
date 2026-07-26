import Foundation
import os

/// Cross-session play: quit a game, land back in the library, and
/// start another game (or restart the same one) without force-closing
/// Empo. The engine runs a session loop and mints a fresh Ruby VM
/// instance per session (`docs/session-switching-plan.md`), so the
/// old superclass-mismatch class of bugs cannot occur. This type owns
/// the feature flag and the per-launch gates the library consults
/// before starting a session.
enum CrossSessionPlay {
    /// Master switch. Off restores the parked single-session UX:
    /// every quit path stays hidden and a clean engine exit shows the
    /// "close from the app switcher" alert.
    static let enabled = true

    /// Sessions started this launch. The memory gate only applies
    /// from the second session on: the first session's footprint is
    /// the pre-cross-session status quo, and blocking it would be a
    /// regression on low-memory devices.
    @MainActor static var sessionsStarted = 0

    /// TEMPORARY soft gate, active only while retired Ruby instances
    /// can leak their memory (the copy-and-load fallback keeps the
    /// previous image resident; see the plan's Stage 2). Once the
    /// Stage 3 container reset lands, retired sessions cost nothing
    /// and this gate becomes a should-never-fire assertion. Without
    /// the gate, iOS would jetsam Empo mid-game with no warning,
    /// which reads as a crash - strictly worse than an honest alert.
    /// 500 MB clears the biggest known Pokemon Essentials forks with
    /// headroom; calibrate against the on-device soak matrix.
    private static let minimumBytesForNextSession = 500 * 1024 * 1024

    enum LaunchBlocker {
        /// Only an already-used Ruby VM remains for this game's Ruby
        /// version (static-island build, or a crashed session left
        /// its instance checked out).
        case dirtyRuby
        /// Retired sessions have eaten too much of the app's memory
        /// budget for another game to launch safely.
        case lowMemory

        var message: String {
            switch self {
            case .dirtyRuby:
                return "This game needs a Ruby engine that has already run a game "
                    + "this session. Close Empo from the app switcher and reopen "
                    + "it to play."
            case .lowMemory:
                return "Empo is running low on memory after the previous game "
                    + "sessions. Close Empo from the app switcher and reopen it "
                    + "to keep playing."
            }
        }
    }

    /// Returns why `game` cannot start a session right now, or nil
    /// when launching is safe. Never blocks the first session of a
    /// launch: with the flag off there is no session 2, and the
    /// engine-side capability is FRESH by construction on a cold
    /// process.
    @MainActor
    static func launchBlocker(for game: GameEntry) -> LaunchBlocker? {
        guard enabled, sessionsStarted > 0 else { return nil }
        guard let container = game.container else { return nil }

        let settings = GameSettings.load(from: container.empoStateURL)
        let metadata = GameMetadata.load(from: container)
        let rubyVersion = GameSession.resolveRubyVersion(
            settings: settings, metadata: metadata
        )
        if mkxp_sessionCapability(rubyVersion) != MKXP_SESSION_CAP_FRESH {
            return .dirtyRuby
        }
        if os_proc_available_memory() < minimumBytesForNextSession {
            return .lowMemory
        }
        return nil
    }
}
