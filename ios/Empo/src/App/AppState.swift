import Foundation
import GameProbe
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
    /// A deliberate in-game dialog (Ruby `msgbox` / `p`), not an error.
    /// The engine thread blocks in `mkxp_presentInfoAndWait()` until
    /// the user dismisses RootView's info alert. The game then
    /// continues to run, so the alert shows no restart framing.
    var infoMessage: String?
    var engineReady = false
    /// Becomes true when an error alert fires during a `.loading`
    /// session. Stays true until the next `selectGame`. The loading
    /// view reads this after the user dismisses the alert, then
    /// switches from the spinner to the error content.
    var sessionHadError = false
    /// The latest release-check result for sideload/dev builds.
    /// `RootView` fills it at launch. Settings and the library banner
    /// read it.
    var updateStatus: UpdateChecker.Status = .unknown
    /// True when the user dismissed the library update banner.
    /// Applies to this launch only.
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

        // Cross-session gate: refuse to start a session that would
        // reuse a dirty Ruby VM or push the app over its memory
        // budget. Surfaces as the standard error alert (phase is
        // still nil, so it's dismiss-to-library).
        if let blocker = CrossSessionPlay.launchBlocker(for: game) {
            errorMessage = blocker.message
            return
        }
        CrossSessionPlay.sessionsStarted += 1

        SaveMigration.migrateLegacySavesIfNeeded(for: container)
        selectedGame = game
        sessionHadError = false
        // Bind the controls layout to this game so edits during play
        // persist to this game's per-game slot (not a global one).
        ControlsLayout.shared.switchGame(id: game.id, container: container)
        PauseManager.shared.reset()
        phase = .loading

        // Everything related to this game lives inside
        // `<container>/`. `Game/` holds the imported files (engine
        // cwd target). `EmpoState/` holds Empo-managed config
        // (mkxp.json, patches.json, game_settings.json,
        // .session-active, etc.). `Logs/` and `Metadata/` complete
        // the per-game tree.
        try? container.ensureSubdirs()
        let gameDir = container.gameURL
        let userDataDir = container.userDataURL
        let stateDir = container.empoStateURL

        GameSettings.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: stateDir,
            gameDirectory: gameDir
        )
        ManagedMkxpConfig.removeLegacyEngineConfigDirectory(in: stateDir)

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

    /// Body text for when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session. Sources: the
    /// game's built-in "Exit to desktop" menu, or postload scripts
    /// that raise Reset after they compile data files.
    /// Only shown when `CrossSessionPlay.enabled` is false; with
    /// cross-session play on, a clean exit returns to the library
    /// silently and the user just picks the next game.
    private static let cleanExitMessage = "The game has ended or requested a restart."

    func consumeCrashRecovery() {
        if let message = session.consumeCrashRecovery() {
            errorMessage = message
        }
    }

    func dismissCrashRecovery() {
        // No-op: CrashTracker.init already cleaned up stale markers
        // at app launch. The recovery flag is only an in-memory bool
        // that consumeRecovery flips.
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

    /// The user dismissed the alert for a session that already
    /// terminated (clean exit with a parting message, or a crash).
    /// With cross-session play on and the engine parked in
    /// waitForGamePath, the library becomes live again; the
    /// per-game capability gate decides whether the next launch is
    /// actually possible. RootView's alert OK handler calls this.
    func finishEndedSession() {
        guard CrossSessionPlay.enabled, phase != nil else { return }
        guard mkxp_isEngineTerminated() != 0, mkxp_isEngineHung() == 0 else { return }
        withAnimation(Motion.snappy) {
            tearDownSessionState()
        }
    }

    /// Resets per-session UI state without a touch on the engine or
    /// the crash marker. The explicit `returnToLibrary` path and the
    /// engine-initiated clean-exit path (game's own "Exit to
    /// desktop" menu, font-install restart, etc.) share it. Both
    /// then drop back to the library through the same transition.
    private func tearDownSessionState() {
        selectedGame = nil
        // Unbind the controls layout. Library-screen UI that reads
        // it then sees a neutral default, and mutations (they should
        // not occur, but still) do not write to the last-played
        // game's slot. `switchGame(nil)` also flushes any pending
        // edits.
        ControlsLayout.shared.switchGame(id: nil, container: nil)
        engineReady = false
        PauseManager.shared.reset()
        phase = nil
    }

    // MARK: - Pause lifecycle

    /// Toggle the pause menu. Same path as the on-screen pause control (SPEC section 8).
    func togglePauseMenu() {
        if PauseManager.shared.pausedGame != nil {
            resumePausedGame()
        } else {
            requestPause()
        }
    }

    func requestPause() {
        // Pause graduated from experimental in May 2026. It is
        // always enabled. The only gate is "a game is playing."
        guard phase == .playing else { return }
        // Pause is the primary return-to-library path (in-game Quit
        // is disabled). Flush play time here so last-played and
        // totals update even though the engine keeps running.
        session.recordSessionPlayTime(for: activeSessionGame)
        EngineState.shared.isBackgroundPause = false
        session.requestPause()
    }

    /// The bridge's paused callback calls this on the main thread.
    /// We ignore background pauses. They stay silent with no UI
    /// transition.
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

    /// We delay the phase change so the hero zoom animation plays
    /// while the library is still visible. The snapshot stays alive.
    /// PlayerView picks it up as a fade-out overlay, so there is no
    /// flash at handoff.
    ///
    /// The `pm.pausedGame == nil` guard in the Task prevents a stray
    /// `phase = .playing` after the user cancels mid-resume with a
    /// return to the library. Before, the chained asyncAfter calls
    /// could race past `returnToLibrary()` and put the app back into
    /// .playing with no game loaded.
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
            AppWindow.resignKeyToSDL()
            // The frame-rendered callback in EngineSessionCoordinator
            // also flips `snapshotCanFade` once the engine has drawn
            // a real frame. This timed fallback guarantees the
            // snapshot fades out even when the callback is late.
            try? await Task.sleep(for: .milliseconds(300))
            pm.snapshotCanFade = true
        }
    }

    /// Removes the crash marker when a healthy session goes to the
    /// background. The foreground path re-creates it, so we still
    /// detect a later crash after resume.
    func clearCrashMarkerForBackground() {
        guard let container = selectedGame?.container else { return }
        session.clearCrashMarker(for: container)
    }

    func restoreCrashMarkerForForeground() {
        guard let container = selectedGame?.container else { return }
        session.restoreCrashMarker(for: container)
    }

    /// Runs on `UIApplication.didEnterBackgroundNotification`.
    /// Flushes wall-clock play time for any live session (in-game
    /// or paused-to-library). Metadata then survives a force-quit.
    func flushSessionPlayTimeForBackground() {
        guard activeSessionGame != nil else { return }
        session.recordSessionPlayTime(for: activeSessionGame)
    }

    /// Restarts the session timer after the app returns from the
    /// background while the game is still in the `.playing` phase.
    func resumeSessionTimingAfterBackground() {
        session.resumeSessionTiming(for: activeSessionGame)
    }
}

// MARK: - RTP launch warning

extension AppState {
    /// True when the game declares RTP in `Game.ini` but Empo has no
    /// configured RTP paths. `GameLibraryView` warns before launch.
    /// The user can continue anyway.
    static func needsRTPLaunchWarning(for container: GameContainer) -> Bool {
        guard !RTPAvailability.isConfigured else { return false }
        return GameRTPRequirement.detect(at: container.gameURL) != nil
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
        // Clean exit with cross-session play on and no alert in
        // flight: the engine parked in waitForGamePath, so drop
        // straight back to the library - the same UI teardown the
        // toolbar quit path uses - and the user picks the next game.
        // The errorMessage == nil guard keeps the boot-gate pattern
        // working: a game that prints a parting message and exits
        // already has the alert up, and setting phase = nil while an
        // alert presents makes SwiftUI swallow the NavigationStack
        // pop. That case routes through RootView's OK handler, which
        // calls finishEndedSession() itself.
        if cleanExit && CrossSessionPlay.enabled && errorMessage == nil {
            withAnimation(Motion.snappy) {
                tearDownSessionState()
            }
            return
        }

        // Alert path (crash exits, boot-gate parting messages, and
        // every exit while the feature flag is off).
        if errorMessage == nil {
            errorMessage =
                cleanExit ? Self.cleanExitMessage : EngineSessionCoordinator.crashMessage
        }
        if phase == .loading {
            sessionHadError = true
        }
        selectedGame = nil
        ControlsLayout.shared.switchGame(id: nil, container: nil)
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

    func coordinatorDidReportEngineInfo(_ message: String) {
        infoMessage = message
    }

    func coordinatorEngineDidPause(snapshot: UIImage?) {
        handlePause(snapshot: snapshot)
    }
}
