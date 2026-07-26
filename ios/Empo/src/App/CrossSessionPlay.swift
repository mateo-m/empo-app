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

    /// Safety-net watermark. With the island allocation zone
    /// (engine: multiruby/alloc_redirect.h + the retire-time
    /// reclaimer), a retired session returns its entire footprint -
    /// heap, pthread keys, GC page mappings - so this gate should
    /// never fire; it exists so a reclaim regression degrades to an
    /// honest alert instead of iOS jetsamming Empo mid-game (which
    /// reads as a crash). The only flow that can still accumulate is
    /// copy-and-load with a failed snapshot, which the soak matrix
    /// treats as a bug. 500 MB clears the biggest known Pokemon
    /// Essentials forks with headroom.
    private static let minimumBytesForNextSession = 500 * 1024 * 1024

    typealias LaunchBlocker = CrossSessionPolicy.Blocker

    /// Returns why `game` cannot start a session right now, or nil
    /// when launching is safe. The decision logic (gate order,
    /// short-circuits) lives in `CrossSessionPolicy.launchBlocker`,
    /// unit-tested in EmpoTests; this wrapper supplies the live
    /// inputs from the engine bridge and the per-game settings.
    ///
    /// `includeMemoryGate: false` is for the quit-and-play flow: it
    /// runs while the just-quit game's memory is still resident, so
    /// the reading would spuriously trip the watermark. The Ruby
    /// capability check stays on - it predicts the post-retire state
    /// and is valid mid-teardown.
    @MainActor
    static func launchBlocker(
        for game: GameEntry,
        includeMemoryGate: Bool = true
    ) -> LaunchBlocker? {
        guard let container = game.container else { return nil }
        return CrossSessionPolicy.launchBlocker(
            enabled: enabled,
            sessionsStarted: sessionsStarted,
            engineHung: mkxp_isEngineHung() != 0,
            includeMemoryGate: includeMemoryGate,
            minimumBytesForNextSession: minimumBytesForNextSession,
            capability: {
                let settings = GameSettings.load(from: container.empoStateURL)
                let metadata = GameMetadata.load(from: container)
                let rubyVersion = GameSession.resolveRubyVersion(
                    settings: settings, metadata: metadata
                )
                switch mkxp_sessionCapability(rubyVersion) {
                case MKXP_SESSION_CAP_FRESH: return .fresh
                case MKXP_SESSION_CAP_DIRTY: return .dirty
                default: return .unavailable
                }
            },
            availableMemoryBytes: { os_proc_available_memory() }
        )
    }
}

extension CrossSessionPolicy.Blocker {
    /// User-facing alert body. Lives outside the pure policy because
    /// the hung message is shared with the termination coordinator.
    @MainActor var message: String {
        switch self {
        case .dirtyRuby:
            return "This game needs a Ruby engine that has already run a game "
                + "this session. Close Empo from the app switcher and reopen "
                + "it to play."
        case .engineHung:
            return EngineTerminationCoordinator.hangMessage
        case .lowMemory:
            return "Empo is running low on memory after the previous game "
                + "sessions. Close Empo from the app switcher and reopen it "
                + "to keep playing."
        }
    }
}
