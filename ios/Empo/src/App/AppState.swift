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

    private let session = EngineSessionCoordinator.shared

    var pendingCrashRecovery: Bool { session.pendingCrashRecovery }

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
        session.delegate = self
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

        session.configureEngine(
            GameSession.LaunchInput(
                game: game,
                container: container,
                gameDir: gameDir,
                stateDir: stateDir,
                userDataDir: userDataDir,
                settings: settings,
                metadata: metadata,
                debugLogsEnabled: AppSettings.shared.debugLogs
            )
        )

        Task { @MainActor in
            await session.launchGamePath(game.path)
        }
    }

    private var activeSessionGame: GameEntry? {
        selectedGame ?? PauseManager.shared.pausedGame
    }

    /// Body text shown when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session: game's built-in
    /// "Exit to desktop" menu, or postload scripts raising Reset
    /// after compiling data files. With cross-session play
    /// disabled (`docs/multi-session.md`) we can't safely return
    /// to the library and launch another game in the same
    /// process; the user has to force-close + reopen. RootView
    /// appends "Close Empo from the app switcher and reopen it
    /// to continue." so the body reads as a single natural
    /// sentence.
    private static let cleanExitMessage = "The game has ended or requested a restart."

    func consumeCrashRecovery() {
        if let message = session.consumeCrashRecovery() {
            errorMessage = message
        }
    }

    func dismissCrashRecovery() {
        // No-op: stale markers were already cleaned up at app
        // launch by CrashTracker.init. The recovery flag is just
        // an in-memory bool that consumeRecovery flips.
        errorMessage = nil
    }

    func returnToLibrary() {
        let engineWasRunning = session.beginReturnToLibrary(
            selectedContainer: selectedGame?.container
        )
        tearDownSessionState()
        session.armHangWatchdogIfNeeded(engineWasRunning: engineWasRunning) { [weak self] message in
            self?.errorMessage = message
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

    // MARK: - Pause lifecycle

    func requestPause() {
        // Pause graduated from experimental in May 2026; always
        // enabled. Only gate is "a game is playing."
        guard phase == .playing else { return }
        // Pause is the primary return-to-library path (in-game Quit
        // is disabled). Flush play time here so last-played and
        // totals update even though the engine keeps running.
        session.recordSessionPlayTime(for: activeSessionGame)
        EngineState.shared.isBackgroundPause = false
        session.requestPause()
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
        session.requestResume()
        session.resumeSessionTiming(for: activeSessionGame)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, pm.pausedGame == nil else { return }
            self.phase = .playing
            // The frame-rendered callback in EngineSessionCoordinator
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
        session.clearCrashMarker(for: container)
    }

    func restoreCrashMarkerForForeground() {
        guard let container = selectedGame?.container else { return }
        session.restoreCrashMarker(for: container)
    }

    /// Called from `UIApplication.didEnterBackgroundNotification`.
    /// Flushes wall-clock play time for any live session (in-game
    /// or paused-to-library) so metadata survives a force-quit.
    func flushSessionPlayTimeForBackground() {
        guard activeSessionGame != nil else { return }
        session.recordSessionPlayTime(for: activeSessionGame)
    }

    /// Restarts the session timer after returning from background
    /// while the game is still in the `.playing` phase.
    func resumeSessionTimingAfterBackground() {
        session.resumeSessionTiming(for: activeSessionGame)
    }
}

extension AppState: EngineSessionCoordinatorDelegate {
    var coordinatorPhase: GamePhase? { phase }
    var coordinatorEngineReady: Bool { engineReady }
    var coordinatorSelectedGame: GameEntry? { selectedGame }
    var coordinatorActiveSessionGame: GameEntry? { activeSessionGame }

    func coordinatorFrameRendered() {
        if phase == .loading, !engineReady {
            Haptics.success()
            engineReady = true
        } else if phase == .playing {
            PauseManager.shared.snapshotCanFade = true
        }
    }

    func coordinatorEngineTerminatedUnexpectedly(cleanExit: Bool) {
        // Both clean and crash exits surface an alert that routes
        // through RootView's dismiss-only branch (phase != nil).
        // With cross-session play disabled (`docs/multi-session.md`)
        // we can't safely return to the library and launch another
        // game in the same process; the only way to play again is
        // to force-close from the app switcher.
        //
        // Intentionally do NOT set phase = nil here: setting phase
        // = nil while an error alert is already presenting causes
        // SwiftUI to swallow the NavigationStack pop. Leaving phase
        // non-nil means the alert OK button sees phase != nil and
        // routes through the dismiss-only handler.
        if errorMessage == nil {
            errorMessage =
                cleanExit ? Self.cleanExitMessage : EngineSessionCoordinator.crashMessage
        }
        if phase == .loading {
            sessionHadError = true
        }
        selectedGame = nil
        ControlsLayout.shared.switchGame(id: nil)
        engineReady = false
        PauseManager.shared.reset()
    }

    func coordinatorGameRectDidChange(_ rect: CGRect) {
        let engineState = EngineState.shared
        if engineState.gameRect != rect {
            engineState.gameRect = rect
        }
    }

    func coordinatorDidReportEngineError(_ message: String) {
        errorMessage = message
    }

    func coordinatorEngineDidPause(snapshot: UIImage?) {
        handlePause(snapshot: snapshot)
    }
}
