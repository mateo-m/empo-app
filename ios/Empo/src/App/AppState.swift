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

    // Assigned in init AFTER the container migration runs:
    // `EngineSessionCoordinator.init` builds a `CrashTracker`,
    // which scans containers for `.session-active` markers.
    // Initializing it at the declaration would run that scan over
    // the un-migrated legacy tree - the marker's container gets
    // renamed or quarantined a moment later and the recovery
    // consume step then misses it.
    private let session: EngineSessionCoordinator

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
        GameContainerMigration.migrateLegacyContainersIfNeeded()
        SaveMigration.migrateAllDiscoveredGamesIfNeeded()
        DataDirectory.healPreLiteralChainsAtLaunch()
        session = EngineSessionCoordinator.shared
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
        // persist to this game's layout profile.
        ControlsLayout.shared.switchGame(id: game.id, container: container, title: game.title)
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
        // Every game gets a shared Documents/Data/<org>/<app>/ data
        // directory. This mirrors how desktop mkxp-z resolves
        // dataPathOrg/dataPathApp through SDL_GetPrefPath for every
        // game, declared or not.
        // The engine compares this path against getcwd output, so
        // it must receive the symlink-resolved spelling (see
        // `engineSpelling` for the /var vs /private/var trap).
        let userDataDir = DataDirectory.engineSpelling(
            of: DataDirectory.resolveAndPrepare(for: container))
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

        // The hop to the next main-actor turn lets SwiftUI commit
        // `phase = .loading` before the engine takes the path.
        Task { @MainActor in
            session.launchGamePath(game.path)
        }
    }

    private var activeSessionGame: GameEntry? {
        selectedGame ?? PauseManager.shared.pausedGame
    }

    /// Body text for when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session. Sources: the
    /// game's built-in "Exit to desktop" menu, or postload scripts
    /// that raise Reset after they compile data files.
    /// Cross-session play is disabled (`ios/Empo/docs/multi-session.md`), so
    /// we cannot safely return to the library and launch another
    /// game in the same process. The user has to force-close and
    /// reopen. RootView appends "Close Empo from the app switcher
    /// and reopen it to continue." so the body reads as one natural
    /// sentence.
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
        // Pause is the only return-to-library path. Flush play time
        // here so last-played and totals update even though the
        // engine keeps running.
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
    /// The `pm.pausedGame == nil` guard in the Task keeps a stray
    /// `phase = .playing` out after the session ends mid-resume.
    /// Before the guard, the chained asyncAfter calls could race
    /// past the teardown and put the app back into .playing with no
    /// game loaded.
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
        // Both clean and crash exits surface an alert that routes
        // through RootView's dismiss-only branch (phase != nil).
        // Cross-session play is disabled (`ios/Empo/docs/multi-session.md`),
        // so we cannot safely return to the library and launch
        // another game in the same process. To play again, the user
        // must force-close from the app switcher.
        //
        // We intentionally do NOT set phase = nil here. If phase
        // becomes nil while an error alert already presents, SwiftUI
        // swallows the NavigationStack pop. Phase stays non-nil, so
        // the alert OK button sees phase != nil and routes through
        // the dismiss-only handler.
        if errorMessage == nil {
            errorMessage =
                cleanExit ? Self.cleanExitMessage : EngineSessionCoordinator.crashMessage
        }
        if phase == .loading {
            sessionHadError = true
        }
        selectedGame = nil
        // Unbind the controls layout. Library-screen UI that reads
        // it then sees a neutral default, and mutations (they should
        // not occur, but still) do not write to the last-played
        // game's slot. `switchGame(nil)` also flushes any pending
        // edits.
        ControlsLayout.shared.switchGame(id: nil, container: nil)
        ScreenRegionApplier.endSession()
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
