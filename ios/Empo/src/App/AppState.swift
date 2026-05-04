import Foundation
import SwiftUI
import Observation

enum GamePhase: Equatable {
    case loading
    case playing
}

@MainActor @Observable
class AppState {
    static let shared = AppState()

    var phase: GamePhase?
    var selectedGame: GameEntry?
    var errorMessage: String?
    var engineReady = false
    private var terminationExpected = false

    private let crashTracker = CrashTracker()
    private let sessionLogger = SessionLogger()
    private let termination = EngineTerminationCoordinator()

    var pendingCrashRecovery: Bool { crashTracker.pendingCrashRecovery }

    private init() {
        registerBridgeCallbacks()
    }


    func selectGame(_ game: GameEntry) {
        let pauseManager = PauseManager.shared
        if let paused = pauseManager.pausedGame, paused.id == game.id {
            resumePausedGame()
            return
        }

        guard phase == nil, pauseManager.pausedGame == nil else { return }
        guard let container = game.container else { return }
        selectedGame = game
        // Bind the controls layout to this game so edits during play
        // persist to this game's per-game slot (not a global one).
        ControlsLayout.shared.switchGame(id: game.id)
        PauseManager.shared.reset()
        phase = .loading

        // Everything related to this game lives inside
        // `<container>/`. `Game/` holds the imported files (engine
        // cwd target). `EmpoState/` holds Empo-managed config
        // (mkxp.json, patches.json, game_settings.json,
        // .session-active, etc.). `Logs/` and `Metadata/` round
        // out the per-game tree.
        try? container.ensureSubdirs()
        let gameDir = container.gameURL
        let stateDir = container.empoStateURL

        // Tell the engine where to find managed config. The engine's
        // Config::read and Patcher constructor check this directory
        // first for mkxp.json and patches.json before falling back
        // to cwd (= the Game/ subdir).
        mkxp_setManagedConfigDir(stateDir.path)

        let settings = GameSettings.load(from: stateDir)

        // syntaxTransform travels via the bridge, NOT mkxp.json,
        // so mkxp.json stays a clean mirror of the developer's
        // engine-config layer. Has to be set before the engine
        // reaches `initSyntaxTransform` (during the RGSS-thread
        // bootstrap kicked off by mkxp_setGamePath later in this
        // method) - selectGame is the right place for it.
        //
        // Important even on multi-Ruby: games that route to Ruby
        // 3.1 (the only Ruby version with the patches applied)
        // still need the LEGACY mode for legacy-grammar PE forks
        // (Vinemon, etc.) whose scripts mix 1.8 syntax with 1.9+
        // runtime methods. Games on 1.8/1.9/3.0 native ignore
        // this setting (no patches in those builds).
        mkxp_setSyntaxTransformMode(
            settings.resolveSyntaxTransformMode(gameDirectory: gameDir)
        )

        // Multi-Ruby (Phase D, MULTI_RUBY_PLAN.md) per-game dispatch.
        // Precedence:
        //   1. settings.rubyVersionOverride (manual user pick in
        //      GameSettingsView's Ruby version picker)
        //   2. metadata.rubyVersion (auto-detected at import time
        //      by RubyVersionDetection)
        //   3. MKXP_RUBY_UNSET → engine falls through to its
        //      legacy direct-link 3.1 path. Hit when neither
        //      override nor detection has tagged a value, e.g.
        //      games imported before this field existed if the
        //      backfill hasn't run yet.
        let metadata = GameMetadata.load(from: container)
        let rubyVersionRaw = settings.rubyVersionOverride ?? metadata.rubyVersion
        let rubyVer: MKXPRubyVersion = {
            switch rubyVersionRaw {
            case 18: return MKXP_RUBY_18
            case 19: return MKXP_RUBY_19
            case 30: return MKXP_RUBY_30
            case 31: return MKXP_RUBY_31
            default: return MKXP_RUBY_UNSET
            }
        }()
        mkxp_setActiveRubyVersion(rubyVer)

        settings.applyToConfig(stateDirectory: stateDir, gameDirectory: gameDir)

        // Apply Empo's curated patches.json (auto-discovered by the
        // engine's Patcher from the managed config dir). Resolves
        // canonical id from either the JGP manifest (preferred) or
        // Game.ini Title. No-op if the game isn't in our registry
        // and no _global rules apply.
        PatcherDistribution.applyToGame(container: container)

        // sessionLogger has to open the per-session log file before
        // any bridge call that writes to `mkxp_debugLog` - otherwise
        // those early lines are silently dropped because the file
        // isn't open yet.
        crashTracker.writeMarker(for: container)
        sessionLogger.beginSession(
            for: game,
            container: container,
            debugLogsEnabled: AppSettings.shared.debugLogs
        )

        // These settings go through the bridge, not mkxp.json
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        mkxp_applyPerGameSettings(alignment.bridgeValue, postload)
        // Default the in-game-keyboard toggle to ON for Pokemon
        // Essentials fan games (Insurgence, Uranium, Reborn, etc.)
        // since their PE-era keyboard scene is the better UX path
        // for those games and our backspace shim in
        // pokemon_input.rb already handles the soft-keyboard case.
        // Non-PE games default to false (use the iOS soft keyboard).
        // The user's explicit toggle (true/false in
        // GameSettings.useInGameKeyboard) always wins over the
        // detector.
        let inGameKeyboardDefault = GameSettings.detectPokemonEssentials(
            in: gameDir, stateDirectory: stateDir
        )
        mkxp_setUseInGameKeyboard(settings.useInGameKeyboard ?? inGameKeyboardDefault)

        // Reset per-session bridge state in one shot. Engine-side
        // `mkxp_resetSessionState` is the canonical list of
        // "process-static state that's intrinsically per-game and
        // would otherwise leak across launches" - the engine
        // author of a new bridge adds their reset there alongside
        // the static declaration, so the host doesn't have to
        // track each bridge individually.
        //
        // Effectively a no-op on feat/multi-ruby-v2 since cross-
        // session play is disabled (QUIT_PATHS_DISABLED.md), but
        // calling it costs nothing and keeps the iOS code in sync
        // with main's expected bridge surface.
        mkxp_resetSessionState()

        // Wait for the RGSS thread to actually finish tearing down any
        // previous session before feeding it the new path. If
        // mkxp_setGamePath is called too early, the engine's own
        // mkxp_setEngineTerminated() runs afterwards and clears the path
        // flag just set, leaving the next session stuck in
        // waitForGamePath forever.
        //
        // awaitEngineTermination returns immediately when no previous
        // session is running, and otherwise parks on a continuation
        // that the engine-terminated callback wakes up. No polling, no
        // wall-clock deadline: the hang watchdog in returnToLibrary is
        // what handles a truly stuck RGSS thread by force-quitting the
        // app.
        //
        // The loading view is already on screen throughout this wait,
        // so it doubles as a "quitting" indicator when the user quickly
        // taps a new game right after quitting.
        Task { @MainActor in
            await termination.awaitEngineTermination()
            mkxp_setGamePath(game.path)
        }
    }

    func recordSessionPlayTime() {
        sessionLogger.recordSessionPlayTime(for: selectedGame)
    }

    private static let crashMessage = "It looks like the game didn't exit cleanly last time. "
        + "Your save data should be fine."

    /// Body text shown when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session: game's built-in
    /// "Exit to desktop" menu, or postload scripts raising Reset
    /// after compiling data files. With cross-session play
    /// disabled (QUIT_PATHS_DISABLED.md) we can't safely return
    /// to the library and launch another game in the same
    /// process — the user has to force-close + reopen. RootView
    /// appends "Close Empo from the app switcher and reopen it
    /// to continue." so the body reads as a single natural
    /// sentence.
    private static let cleanExitMessage = "The game has ended or requested a restart."

    func consumeCrashRecovery() {
        guard crashTracker.pendingCrashRecovery else { return }
        crashTracker.consumeRecovery()
        errorMessage = Self.crashMessage
    }

    func dismissCrashRecovery() {
        // No-op: stale markers were already cleaned up at app
        // launch by CrashTracker.init. The recovery flag is just
        // an in-memory bool that consumeRecovery flips.
        errorMessage = nil
    }

    func returnToLibrary() {
        terminationExpected = true
        recordSessionPlayTime()
        if let container = selectedGame?.container {
            crashTracker.removeMarker(for: container)
        }

        // Only talk to the engine if it's still running. After a crash
        // the terminated callback has already fired and re-arming the
        // hang watchdog here would trip a spurious "previous game
        // stopped responding" alert 3s later.
        let engineWasRunning = mkxp_isEngineTerminated() == 0
        if engineWasRunning {
            mkxp_requestTerminate()
        }

        tearDownSessionState()

        if engineWasRunning {
            termination.armHangWatchdog { [weak self] message in
                self?.errorMessage = message
            }
        }
    }

    /// Resets per-session UI state without touching the engine or
    /// crash marker. Shared by the explicit `returnToLibrary` path
    /// and the engine-initiated clean-exit path (game's own
    /// "Exit to desktop" menu, font-install restart, etc.) so both
    /// drop back to the library through the same transition.
    private func tearDownSessionState() {
        selectedGame = nil
        // Unbind the controls layout so any library-screen UI that
        // reads it sees a neutral default, and mutations (shouldn't
        // happen, but still) don't write to the last-played game's
        // slot. `switchGame(nil)` also flushes any pending edits.
        ControlsLayout.shared.switchGame(id: nil)
        engineReady = false
        PauseManager.shared.reset()
        phase = nil
    }

    // armLoadingEscapeForceQuit() wrapper removed 2026-05-02 along
    // with the underlying coordinator helper. See
    // QUIT_PATHS_DISABLED.md.


    // MARK: - Pause lifecycle

    func requestPause() {
        // Pause graduated from experimental in May 2026; always
        // enabled. Only gate is "a game is actually playing."
        guard phase == .playing else { return }
        EngineState.shared.isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Called on the main thread from the bridge's paused callback.
    /// Background pauses are ignored — they stay silent with no UI transition.
    func handlePause(snapshot: UIImage?) {
        guard phase == .playing else { return }
        if EngineState.shared.isBackgroundPause { return }
        let pm = PauseManager.shared
        pm.pauseSnapshot = snapshot
        pm.pausedGame = selectedGame
        withAnimation(Motion.snappy) {
            phase = nil
        }
    }

    /// Phase change is delayed so the hero zoom animation plays while
    /// the library is still visible. The snapshot stays alive — PlayerView
    /// picks it up as a fade-out overlay so there's no flash at handoff.
    ///
    /// The `pm.pausedGame == nil` guard in the Task prevents a stray
    /// `phase = .playing` after the user cancelled mid-resume by
    /// returning to the library; previously the chained asyncAfter
    /// calls could race past `returnToLibrary()` and put the app back
    /// into .playing with no game loaded.
    func resumePausedGame() {
        let pm = PauseManager.shared
        guard pm.pausedGame != nil else { return }
        pm.pausedGame = nil
        pm.snapshotCanFade = false
        mkxp_requestResume()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, pm.pausedGame == nil else { return }
            self.phase = .playing
            // The frame-rendered callback in registerBridgeCallbacks
            // also flips `snapshotCanFade` once the engine has drawn
            // a real frame; this timed fallback just guarantees the
            // snapshot fades out even if the callback is delayed.
            try? await Task.sleep(for: .milliseconds(300))
            pm.snapshotCanFade = true
        }
    }


    /// Remove the crash marker when backgrounding a healthy session.
    /// Re-creates it when the app returns to foreground so a subsequent
    /// crash after resume is still detected.
    func clearCrashMarkerForBackground() {
        guard let container = selectedGame?.container else { return }
        crashTracker.removeMarker(for: container)
    }

    func restoreCrashMarkerForForeground() {
        guard let container = selectedGame?.container else { return }
        crashTracker.writeMarker(for: container)
    }

    private func registerBridgeCallbacks() {
        // First frame rendered — fresh start transitions to .playing,
        // resume signals the snapshot can fade.
        mkxp_setFrameRenderedCallback({ _ in
            Task { @MainActor in
                let state = AppState.shared
                if state.phase == .loading, !state.engineReady {
                    Haptics.success()
                    state.engineReady = true
                } else if state.phase == .playing {
                    PauseManager.shared.snapshotCanFade = true
                }
            }
        }, nil)

        mkxp_setEngineTerminatedCallback({ _ in
            Task { @MainActor in
                let state = AppState.shared
                // Engine ack'd termination: cancel the hang watchdog
                // and wake selectGame awaiters.
                state.termination.handleEngineTerminatedAck()
                state.recordSessionPlayTime()
                if let container = state.selectedGame?.container {
                    state.crashTracker.removeMarker(for: container)
                }
                GameLibrary.shared.reload()

                if !state.terminationExpected && state.phase != nil {
                    let cleanExit = mkxp_didEngineExitCleanly() != 0
                    // Both clean and crash exits surface an alert
                    // that routes through RootView's dismiss-only
                    // branch (phase != nil). With cross-session
                    // play disabled (QUIT_PATHS_DISABLED.md,
                    // MRUBY_POSTMORTEM.md) we can't safely return
                    // to the library and launch another game in
                    // the same process — the only way to play
                    // again is to force-close from the app switcher.
                    //
                    // Intentionally do NOT set phase = nil here:
                    // setting phase = nil while an error alert is
                    // already presenting causes SwiftUI to swallow
                    // the NavigationStack pop. Leaving phase
                    // non-nil means the alert OK button sees
                    // phase != nil and routes through the dismiss-
                    // only handler.
                    if state.errorMessage == nil {
                        state.errorMessage = cleanExit
                            ? AppState.cleanExitMessage
                            : AppState.crashMessage
                    }
                    state.selectedGame = nil
                    ControlsLayout.shared.switchGame(id: nil)
                    state.engineReady = false
                    PauseManager.shared.reset()
                }
                state.terminationExpected = false
            }
        }, nil)

        mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
            let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            Task { @MainActor in
                let engineState = EngineState.shared
                if engineState.gameRect != newRect {
                    engineState.gameRect = newRect
                }
            }
        }, nil)

        mkxp_setErrorMessageCallback({ msg, _ in
            guard let msg else { return }
            let message = String(cString: msg)
            Task { @MainActor in
                AppState.shared.errorMessage = message
            }
        }, nil)

        // Engine paused — capture snapshot while lock is held.
        mkxp_setPausedCallback({ _ in
            var snapshotImage: UIImage?
            var w: Int32 = 0
            var h: Int32 = 0
            if mkxp_getSnapshotSize(&w, &h), w > 0, h > 0 {
                let totalBytes = Int(w) * Int(h) * 4
                var buffer = [UInt8](repeating: 0, count: totalBytes)
                if mkxp_copySnapshotRGBA(&buffer, Int32(totalBytes), &w, &h) {
                    let data = Data(buffer)
                    let bytesPerRow = Int(w) * 4
                    if let provider = CGDataProvider(data: data as CFData),
                       let cgImage = CGImage(
                           width: Int(w), height: Int(h),
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bytesPerRow,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider,
                           decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent) {
                        snapshotImage = UIImage(cgImage: cgImage)
                    }
                }
            }

            Task { @MainActor in
                AppState.shared.handlePause(snapshot: snapshotImage)
            }
        }, nil)

        mkxp_setResumedCallback({ _ in }, nil)
    }

}
