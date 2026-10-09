import Foundation
import GameProbe
import Observation
import SwiftUI

enum GamePhase: Equatable {
    case loading
    case playing
    /// The game closed itself, or stopped with an error. `started` is
    /// false when that happened before its first frame.
    /// `GameLoadingView` says which.
    case ended(clean: Bool, started: Bool)
}

@MainActor @Observable
class AppState {
    static let shared = AppState()

    var phase: GamePhase?
    var selectedGame: GameEntry?
    var errorMessage: String?
    /// A deliberate in-game dialog (Ruby `msgbox` / `p`), not an error.
    /// The core blocks its game thread until the user dismisses
    /// RootView's info alert. The game then
    /// continues to run, so the alert shows no restart framing.
    var infoMessage: String?
    var engineReady = false
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
        DataDirectory.removeEmptyFolders()
        session = EngineSessionCoordinator.shared
        session.delegate = self
    }

    func selectGame(_ game: GameEntry) {
        let pauseManager = PauseManager.shared
        if let paused = pauseManager.pausedGame, paused.id == game.id {
            resumePausedGame()
            return
        }

        guard phase == nil, pauseManager.pausedGame == nil, resumeTask == nil else { return }
        guard let container = game.container,
            let core = GameCores.core(forGameAt: container.gameURL), core.isInThisBuild
        else { return }
        SaveMigration.migrateLegacySavesIfNeeded(for: container)
        selectedGame = game
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
        // The engine compares this path against getcwd output, so
        // it must receive the symlink-resolved spelling (see
        // `engineSpelling` for the /var vs /private/var trap).
        let userDataDir = DataDirectory.resolveAndPrepare(for: container, core: core)
            .map(DataDirectory.engineSpelling(of:))
        let stateDir = container.empoStateURL

        ManagedMkxpConfig.migrateDisplaySettingsIfNeeded(stateDirectory: stateDir)

        let settings = GameSettings.load(from: stateDir)

        session.configureEngine(
            GameSession.LaunchInput(
                game: game,
                container: container,
                userDataDir: userDataDir,
                core: core,
                settings: settings,
                debugLogsEnabled: AppSettings.shared.debugLogs
            )
        )

        // The hop to the next main-actor turn lets SwiftUI commit
        // `phase = .loading` before the engine takes the path.
        Task { @MainActor in
            session.launchGamePath(game.path)
        }
    }

    /// True when the paused game can end, so another game can start
    /// in its place (`ios/Empo/docs/multi-session.md`).
    var canKillPausedGame: Bool {
        PauseManager.shared.pausedGame != nil && session.canEndGame
    }

    func killPausedGame() {
        guard canKillPausedGame, let paused = PauseManager.shared.pausedGame else { return }
        session.note("The paused game closes.")
        session.killSession(of: paused)
        clearEndedGame()
    }

    /// True when a game that loads too long or stops responding can
    /// end at once. Only a game process can: Empo ends it, and nothing
    /// of it stays in the app.
    var canEndStuckGame: Bool {
        session.runner == .gameProcess
    }

    func cancelLoading() {
        guard canEndStuckGame, phase == .loading else { return }
        session.note("The player stopped the loading.")
        session.recordSessionPlayTime(for: selectedGame)
        session.killSession(of: selectedGame)
        clearEndedGame()
        phase = nil
    }

    /// A hung core cannot pause, so its process ends at once.
    func endStuckGame() {
        guard canEndStuckGame else { return }
        session.note("The game stopped responding, and Empo ended it.")
        session.recordSessionPlayTime(for: activeSessionGame)
        session.killSession(of: activeSessionGame)
        clearEndedGame()
        phase = nil
    }

    /// True when the game ended and can leave the app, so the user
    /// can go back to the library and start another game.
    var canLeaveEndedGame: Bool {
        guard case .ended = phase else { return false }
        return session.canEndGame
    }

    func leaveEndedGame() {
        guard canLeaveEndedGame else { return }
        session.killSession(of: nil)
        phase = nil
    }

    @ObservationIgnored private var quitOnPause = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?

    /// Pauses the game, so the library comes back the same way, and
    /// kills it once the core says it paused. The game is never marked
    /// paused: the library draws that mark at once, and a mark cleared
    /// in the same turn stayed on the Continue playing card.
    var canQuitGame: Bool {
        phase == .playing && session.canEndGame
    }

    func quitGame() {
        guard canQuitGame else { return }
        quitOnPause = true
        requestPause()
    }

    private var activeSessionGame: GameEntry? {
        selectedGame ?? PauseManager.shared.pausedGame
    }

    func consumeCrashRecovery() {
        if let message = session.consumeCrashRecovery() {
            errorMessage = message
        }
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
        // A quit can meet a background pause: the app went to the
        // background before the game paused for the quit.
        if quitOnPause {
            session.note("The player quit the game.")
            session.killSession(of: selectedGame)
            clearEndedGame()
            withAnimation(Motion.snappy) {
                phase = nil
            }
            return
        }
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
    /// A teardown cancels `resumeTask`, so a session that ends
    /// mid-resume does not put the app back into .playing with no
    /// game loaded.
    func resumePausedGame() {
        let pm = PauseManager.shared
        guard pm.pausedGame != nil else { return }
        pm.pausedGame = nil
        pm.snapshotCanFade = false
        session.requestResume()
        session.resumeSessionTiming(for: activeSessionGame)

        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.resumeTask = nil
            self.phase = .playing
            AppWindow.resignKeyToGame()
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

// MARK: - Missing game core

extension AppState {
    /// The core the game needs, when this build does not carry it, and
    /// nil when it does. `GameLibraryView` refuses the tap.
    ///
    /// Import refuses such a game too, so this covers a library the user
    /// filled with a build that had more cores.
    static func missingCore(for container: GameContainer) -> (any GameCore)? {
        guard let core = GameCores.core(forGameAt: container.gameURL), !core.isInThisBuild else {
            return nil
        }
        return core
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
        // We intentionally do NOT set phase = nil here. If phase
        // becomes nil while an error alert already presents, SwiftUI
        // swallows the NavigationStack pop.
        phase = .ended(clean: cleanExit, started: phase == .playing)
        clearEndedGame()
    }

    private func clearEndedGame() {
        quitOnPause = false
        resumeTask?.cancel()
        resumeTask = nil
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

    func coordinatorPausedGameStopped() {
        // A game in the resume transition is no longer paused, and the
        // library still shows.
        guard resumeTask != nil else { return killPausedGame() }
        session.killSession(of: selectedGame)
        clearEndedGame()
    }

    func coordinatorGameRectDidChange(_ rect: CGRect) {
        let engineState = EngineState.shared
        if engineState.gameRect != rect {
            engineState.gameRect = rect
        }
    }

    func coordinatorDidReportEngineError(_ message: String) {
        session.note("Error shown: \(message)")
        errorMessage = message
    }

    func coordinatorDidReportEngineInfo(_ message: String) {
        infoMessage = message
    }

    func coordinatorEngineDidPause(snapshot: UIImage?) {
        handlePause(snapshot: snapshot)
    }
}
