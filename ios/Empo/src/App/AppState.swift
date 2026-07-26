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

    /// The live `CoreSession` for the selected game, instantiated
    /// per launch by the game's `resolvedCoreKind` (`selectGame`).
    /// mkxp's is a thin adapter over the process-global
    /// `EngineSessionCoordinator` (same calls as before the cores
    /// seam); rmWeb's owns a disposable WKWebView. Nil outside a
    /// session. Survives pause (the session keeps running); cleared
    /// by `tearDownSessionState` and unexpected termination.
    private(set) var activeSession: (any CoreSession)?

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

        let input = GameSession.LaunchInput(
            game: game,
            container: container,
            gameDir: gameDir,
            stateDir: stateDir,
            userDataDir: userDataDir,
            settings: settings,
            metadata: metadata,
            debugLogsEnabled: AppSettings.shared.debugLogs
        )

        // Launch through the session type registered for this
        // game's core (docs/plans/emulator-cores.md).
        switch metadata.resolvedCoreKind {
        case .rmWeb:
            #if canImport(RmWebHost)
                // DORMANT: the importer still rejects MV/MZ (phase
                // 2), so no library entry resolves to `.rmWeb` yet.
                // This branch activates when the import gate opens
                // after on-device validation.
                guard
                    let provider = CoreRegistry.shared.core(for: .rmWeb)
                        as? any SessionProviding,
                    let newSession = provider.makeSession(launch: input, delegate: self)
                else {
                    failLaunchOfUnplayableGame()
                    return
                }
                activeSession = newSession
                newSession.start()
            #else
                // The rmweb-core submodule is not in this build, so
                // there is no runtime for this game. Unreachable
                // while the import gate rejects MV/MZ; fail like an
                // invalid game rather than feeding it to the mkxp
                // engine.
                failLaunchOfUnplayableGame()
            #endif
        case .mkxp, .unsupported:
            // `MkxpSession.start()` is the exact
            // configureEngine + launchGamePath sequence this method
            // ran inline before the cores seam - same calls, same
            // order, same threads (mkxp stays bit-identical).
            // `.unsupported` keeps the pre-cores behavior: builds
            // before `coreKind` existed ran every import through
            // the mkxp engine.
            let newSession = MkxpSession(launch: input)
            activeSession = newSession
            newSession.start()
        }
    }

    /// Launch-time analogue of the import validator's "can't play
    /// this" surface: unwind the just-started session state so
    /// `phase` is nil again, then show a plain library-level alert
    /// (RootView's dismiss-only "Something went wrong" copy, with
    /// no force-close framing).
    private func failLaunchOfUnplayableGame() {
        tearDownSessionState()
        errorMessage = "This game can't be played by this version of Empo."
    }

    private var activeSessionGame: GameEntry? {
        selectedGame ?? PauseManager.shared.pausedGame
    }

    /// Body text for when the engine signals a clean exit
    /// (Ruby `SystemExit` / `Reset`) mid-session. Sources: the
    /// game's built-in "Exit to desktop" menu, or postload scripts
    /// that raise Reset after they compile data files.
    /// Cross-session play is disabled (`docs/multi-session.md`), so
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

    func returnToLibrary() {
        // Capability branch (`quitToLibrary`): a session whose core
        // can end a game without killing the process (rmWeb)
        // terminates cleanly and frees the app for another game -
        // no "close Empo from the app switcher" alert, no hang
        // watchdog. mkxp declares `quitToLibrary: false` and keeps
        // the exact pre-cores path below (docs/multi-session.md).
        if let activeSession, activeSession.capabilities.quitToLibrary {
            // Same play-time bookkeeping the mkxp path gets from
            // beginReturnToLibrary, flushed before the session
            // object goes away.
            session.recordSessionPlayTime(for: activeSessionGame)
            activeSession.requestTerminate()
            tearDownSessionState()
            return
        }
        // mkxp-specific: crash markers, play time, the termination
        // handshake, and the hang watchdog all live in the
        // process-global coordinator.
        let engineWasRunning = session.beginReturnToLibrary(
            selectedContainer: selectedGame?.container
        )
        tearDownSessionState()
        session.armHangWatchdogIfNeeded(engineWasRunning: engineWasRunning) { [weak self] message in
            self?.errorMessage = message
        }
    }

    /// Resets per-session UI state without a touch on the engine or
    /// the crash marker. The explicit `returnToLibrary` path and the
    /// engine-initiated clean-exit path (game's own "Exit to
    /// desktop" menu, font-install restart, etc.) share it. Both
    /// then drop back to the library through the same transition.
    private func tearDownSessionState() {
        selectedGame = nil
        // Drop the per-launch session object. mkxp's adapter holds
        // no engine state, so releasing it cannot affect the engine
        // (the coordinator stays process-global); a terminating
        // rmWeb session keeps itself alive until its saves flush.
        activeSession = nil
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
        // Route through the live session: mkxp's adapter makes the
        // same mkxp_requestPause call this method made directly
        // before the cores seam. The no-session fallback preserves
        // the pre-cores behavior verbatim.
        if let activeSession {
            activeSession.requestPause()
        } else {
            session.requestPause()
        }
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
        // Same routing note as requestPause: mkxp's adapter is a
        // mechanical indirection over the identical coordinator
        // call.
        if let activeSession {
            activeSession.requestResume()
        } else {
            session.requestResume()
        }
        session.resumeSessionTiming(for: activeSessionGame)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, pm.pausedGame == nil else { return }
            self.phase = .playing
            // mkxp-specific: hands UIKit key-window status back to
            // SDL's window. Harmless for `.view` surface sessions
            // (there is a non-SDL window to make key, but keyboard
            // routing for those is a rmweb-activation follow-up).
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
        // Cross-session play is disabled (`docs/multi-session.md`),
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
        activeSession = nil
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

// MARK: - CoreSessionDelegate

/// Events from sessions created through the `CoreSession` seam.
/// Today only rmWeb delivers here - mkxp's events keep arriving
/// through the `EngineSessionCoordinatorDelegate` conformance above
/// (unchanged wiring, bit-identical behavior) - so each method
/// funnels into the same handler its coordinator twin uses.
extension AppState: CoreSessionDelegate {
    func sessionFrameRendered() {
        coordinatorFrameRendered()
    }

    func sessionTerminated(cleanExit: Bool) {
        // Capability branch (`sequentialSessions`): a core whose
        // sessions are disposable (rmWeb - the WKWebView is gone,
        // the process is healthy) resets phase/pause state so the
        // library can start another game, instead of the mkxp-only
        // "close Empo from the app switcher" alert flow
        // (docs/multi-session.md, "What still happens at engine
        // shutdown").
        guard let activeSession, activeSession.capabilities.sequentialSessions else {
            coordinatorEngineTerminatedUnexpectedly(cleanExit: cleanExit)
            return
        }
        // Reset phase (and pause state) BEFORE any alert appears,
        // so RootView's error alert takes the phase == nil branch
        // (plain dismiss, no force-close framing) and the library
        // is ready for the next launch.
        tearDownSessionState()
        if !cleanExit, errorMessage == nil {
            errorMessage =
                "The game ended unexpectedly. You can start it again from the library."
        }
    }

    func sessionGameRectDidChange(_ rect: CGRect) {
        coordinatorGameRectDidChange(rect)
    }

    func sessionDidReportError(_ message: String) {
        coordinatorDidReportEngineError(message)
    }

    func sessionDidReportInfo(_ message: String) {
        coordinatorDidReportEngineInfo(message)
    }

    func sessionDidPause(snapshot: UIImage?) {
        handlePause(snapshot: snapshot)
    }
}
