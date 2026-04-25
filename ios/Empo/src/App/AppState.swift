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

    /// Preserved as a namespaced alias so call sites outside AppState
    /// don't reach into SessionLogger directly.
    static var logsDirectory: URL { SessionLogger.logsDirectory }

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
        selectedGame = game
        // Bind the controls layout to this game so edits during play
        // persist to this game's per-game slot (not a global one).
        ControlsLayout.shared.switchGame(id: game.id)
        PauseManager.shared.reset()
        phase = .loading

        let gameDir = URL(fileURLWithPath: game.path)

        // Per-game managed config (mkxp.json, patches.json,
        // game_settings.json, configuration.json) lives in
        // `Documents/EmpoState/<id>/` so the imported game folder
        // stays a faithful mirror of what the user dropped in.
        let stateDir = EmpoState.directory(forGameId: game.id)

        // Tell the engine where to find managed config. The engine's
        // Config::read and Patcher constructor check this directory
        // first for mkxp.json and patches.json before falling back
        // to cwd (= game folder).
        mkxp_setManagedConfigDir(stateDir.path)

        let settings = GameSettings.load(from: stateDir)
        settings.applyToConfig(stateDirectory: stateDir, gameDirectory: gameDir)

        // Apply Empo's curated patches.json (auto-discovered by the
        // engine's Patcher from the managed config dir). Resolves
        // canonical id from either the JGP manifest (preferred) or
        // Game.ini Title. No-op if the game isn't in our registry
        // and no _global rules apply.
        PatcherDistribution.applyToGame(at: stateDir, gameDirectory: gameDir, gameId: game.id)

        // These settings go through the bridge, not mkxp.json
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        mkxp_applyPerGameSettings(alignment.bridgeValue, postload)

        crashTracker.writeMarker()
        sessionLogger.beginSession(for: game, debugLogsEnabled: AppSettings.shared.debugLogs)

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

    func consumeCrashRecovery() {
        guard crashTracker.pendingCrashRecovery else { return }
        crashTracker.consumeRecovery()
        errorMessage = Self.crashMessage
    }

    func dismissCrashRecovery() {
        crashTracker.removeMarker()
        errorMessage = nil
    }

    func returnToLibrary() {
        terminationExpected = true
        recordSessionPlayTime()
        crashTracker.removeMarker()

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
    /// "Exit to desktop" menu) so both drop back to the library
    /// through the same transition.
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

    func armLoadingEscapeForceQuit() {
        termination.armLoadingEscapeForceQuit()
    }


    // MARK: - Pause lifecycle

    func requestPause() {
        guard AppSettings.shared.isEnabled(.gamePause),
              phase == .playing else { return }
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
        crashTracker.removeMarker()
    }

    func restoreCrashMarkerForForeground() {
        crashTracker.writeMarker()
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
                state.crashTracker.removeMarker()
                GameLibrary.shared.reload()

                if !state.terminationExpected && state.phase != nil {
                    let cleanExit = mkxp_didEngineExitCleanly() != 0
                    if cleanExit {
                        // Ruby raised SystemExit (e.g. the game's own
                        // "Exit to desktop" menu): drop back to the
                        // library silently through the shared teardown.
                        state.tearDownSessionState()
                    } else {
                        // Preserve a Ruby/engine error message if the error callback
                        // already set one; otherwise fall back to the generic crash text.
                        // Intentionally do NOT set phase = nil here: setting phase = nil
                        // while an error alert is already presenting, SwiftUI swallows the
                        // NavigationStack pop. Leaving phase non-nil means the alert OK
                        // button sees phase != nil, calls returnToLibrary(), and the pop
                        // happens cleanly after the alert is dismissed.
                        if state.errorMessage == nil {
                            state.errorMessage = AppState.crashMessage
                        }
                        state.selectedGame = nil
                        ControlsLayout.shared.switchGame(id: nil)
                        state.engineReady = false
                        PauseManager.shared.reset()
                    }
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
