import Foundation
import Observation
import SwiftUI

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
    /// Set when an error alert fires during a `.loading` session
    /// and stays true until the next `selectGame`. The loading
    /// view reads this after the user dismisses the alert to
    /// switch from spinner to error content.
    var sessionHadError = false
    /// Latest release check result for sideload/dev builds. Filled at
    /// launch from `RootView`; Settings and the library banner read it.
    var updateStatus: UpdateChecker.Status = .unknown
    /// Library update banner dismissed for this launch only.
    var updateBannerDismissed = false
    private var terminationExpected = false

    private let crashTracker = CrashTracker()
    private let sessionLogger = SessionLogger()
    private let termination = EngineTerminationCoordinator()

    var pendingCrashRecovery: Bool { crashTracker.pendingCrashRecovery }

    func checkForUpdatesIfStale() async {
        guard UpdateChecker.isSideloadOrDevBuild else { return }
        updateStatus = .checking
        let result = await UpdateChecker.checkIfStale()
        withAnimation(Motion.standard) {
            updateStatus = result
        }
    }

    func checkForUpdatesNow() async {
        guard UpdateChecker.isSideloadOrDevBuild else { return }
        updateStatus = .checking
        let result = await UpdateChecker.checkNow()
        withAnimation(Motion.standard) {
            updateStatus = result
        }
    }

    private init() {
        SaveMigration.migrateAllDiscoveredGamesIfNeeded()
        sessionLogger.onPlayTimeFlushed = { gameID in
            GameLibrary.shared.refreshGameEntry(id: gameID)
        }
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
        SaveMigration.migrateLegacySavesIfNeeded(for: container)
        selectedGame = game
        sessionHadError = false
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
        let userDataDir = container.userDataURL
        let stateDir = container.empoStateURL

        var settings = GameSettings.load(from: stateDir)
        var metadata = GameMetadata.load(from: container)
        GameSession.refreshMetadataIfNeeded(
            settings: settings,
            metadata: &metadata,
            container: container,
            forceRefresh: true
        )

        GameSession.configureEngine(
            GameSession.LaunchInput(
                game: game,
                container: container,
                gameDir: gameDir,
                stateDir: stateDir,
                userDataDir: userDataDir,
                settings: settings,
                metadata: metadata,
                debugLogsEnabled: AppSettings.shared.debugLogs
            ),
            crashTracker: crashTracker,
            sessionLogger: sessionLogger
        )

        Task { @MainActor in
            await termination.awaitEngineTermination()
            mkxp_setGamePath(game.path)
        }
    }

    private var activeSessionGame: GameEntry? {
        selectedGame ?? PauseManager.shared.pausedGame
    }

    private func recordSessionPlayTime() {
        sessionLogger.recordSessionPlayTime(for: activeSessionGame)
    }

    private func resumeSessionTiming() {
        guard let game = activeSessionGame else { return }
        sessionLogger.resumeSessionTiming(for: game)
    }

    private static let crashMessage =
        "It looks like the game didn't exit cleanly last time. "
        + "Your save data should be fine."

    /// Body text shown when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session: game's built-in
    /// "Exit to desktop" menu, or postload scripts raising Reset
    /// after compiling data files. With cross-session play
    /// disabled (QUIT_PATHS_DISABLED.md) we can't safely return
    /// to the library and launch another game in the same
    /// process; the user has to force-close + reopen. RootView
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
        // enabled. Only gate is "a game is playing."
        guard phase == .playing else { return }
        // Pause is the primary return-to-library path (in-game Quit
        // is disabled). Flush play time here so last-played and
        // totals update even though the engine keeps running.
        recordSessionPlayTime()
        EngineState.shared.isBackgroundPause = false
        mkxp_requestPause()
    }

    /// Called on the main thread from the bridge's paused callback.
    /// Background pauses are ignored; they stay silent with no UI transition.
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
    /// the library is still visible. The snapshot stays alive; PlayerView
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
        resumeSessionTiming()

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

    /// Called from `UIApplication.didEnterBackgroundNotification`.
    /// Flushes wall-clock play time for any live session (in-game
    /// or paused-to-library) so metadata survives a force-quit.
    func flushSessionPlayTimeForBackground() {
        guard activeSessionGame != nil else { return }
        recordSessionPlayTime()
    }

    /// Restarts the session timer after returning from background
    /// while the game is still in the `.playing` phase.
    func resumeSessionTimingAfterBackground() {
        resumeSessionTiming()
    }

    private func registerBridgeCallbacks() {
        // First frame rendered; fresh start transitions to .playing,
        // resume signals the snapshot can fade.
        mkxp_setFrameRenderedCallback(
            { _ in
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

        mkxp_setEngineTerminatedCallback(
            { _ in
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
                        // the same process; the only way to play
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
                            state.errorMessage =
                                cleanExit
                                ? AppState.cleanExitMessage
                                : AppState.crashMessage
                        }
                        if state.phase == .loading {
                            state.sessionHadError = true
                        }
                        state.selectedGame = nil
                        ControlsLayout.shared.switchGame(id: nil)
                        state.engineReady = false
                        PauseManager.shared.reset()
                    }
                    state.terminationExpected = false
                }
            }, nil)

        mkxp_setGameRectChangedCallback(
            { x, y, w, h, _ in
                let newRect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                Task { @MainActor in
                    let engineState = EngineState.shared
                    if engineState.gameRect != newRect {
                        engineState.gameRect = newRect
                    }
                }
            }, nil)

        mkxp_setErrorMessageCallback(
            { msg, _ in
                guard let msg else { return }
                let message = String(cString: msg)
                // Always async: this callback can fire from inside SDL's
                // event handler on the main thread. Synchronous UIKit /
                // SwiftUI updates there re-enter UIKit while SDL is
                // dispatching and have crashed the process to the
                // home screen.
                DispatchQueue.main.async {
                    AppState.shared.errorMessage = message
                    AppWindow.setAllowKeyWindow(true)
                }
            }, nil)

        // Engine paused; capture snapshot while lock is held.
        mkxp_setPausedCallback(
            { _ in
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
                                bitmapInfo: CGBitmapInfo(
                                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider,
                                decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent)
                        {
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
