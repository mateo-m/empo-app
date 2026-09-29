import Foundation
import GameProbe

/// Owns per-game engine launch: bridge configuration, patch
/// distribution, logging, and the deferred `gamecore_setGamePath` handoff.
@MainActor
enum GameSession {

    struct LaunchInput {
        let game: GameEntry
        let container: GameContainer
        let gameDir: URL
        let stateDir: URL
        /// Engine-writable data directory (`System.data_directory`),
        /// resolved by `DataDirectory` into the shared
        /// `Documents/Data/<org>/<app>/` tree.
        let userDataDir: URL
        let core: any GameCore
        let settings: GameSettings
        let debugLogsEnabled: Bool
    }

    /// Apply managed dirs, the core's own settings, patches, session
    /// logging, and bridge session config. Does not set
    /// `gamecore_setGamePath`. The caller awaits engine termination first.
    static func configureEngine(
        _ input: LaunchInput,
        crashTracker: CrashTracker,
        sessionLogger: SessionLogger
    ) {
        let container = input.container
        let game = input.game
        let gameDir = input.gameDir
        let stateDir = input.stateDir
        let settings = input.settings
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment

        GameSettings.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: stateDir,
            gameDirectory: gameDir
        )
        ManagedMkxpConfig.removeLegacyEngineConfigDirectory(in: stateDir)

        let overlayJSON = EngineConfigProjector.overlayJSONString(
            stateDirectory: stateDir,
            gameDirectory: gameDir
        )
        if let overlayJSON {
            overlayJSON.withCString { gamecore_setConfigOverlayJSON($0) }
            logEngineConfigOverlay(overlayJSON, container: container)
        } else {
            gamecore_setConfigOverlayJSON(nil)
        }

        // The core reads its settings in gamecore_applySessionConfig.
        input.core.launch(container)

        DataDirectory.ensureFontsRoot()
        input.userDataDir.path.withCString { userDataPtr in
            DataDirectory.fontsRootURL.path.withCString { fontsPtr in
                var config = GameCoreSessionConfig()
                config.userDataDirectory = userDataPtr
                config.sharedFontsDirectory = fontsPtr
                config.verticalAlignment = alignment.bridgeValue
                gamecore_applySessionConfig(&config)
            }
        }

        crashTracker.writeMarker(for: container)
        sessionLogger.beginSession(
            for: game,
            container: container,
            debugLogsEnabled: input.debugLogsEnabled
        )

        gamecore_resetSessionState()
        // After the reset (which clears the previous session's
        // region) and before boot: the engine's first recalc reads
        // the bridge statics, so the region is set pre-boot.
        ScreenRegionApplier.beginSession(container: container)
        gamecore_setGameControllerCaptureEnabled(false)
        // Seed the touch-mouse atomic before boot.
        // `gamecore_resetSessionState` above leaves it alone, so without
        // this the new game inherits the previous game's value until
        // `PlayerRuntimeState.reconcile` runs. That call owns every
        // later push, including the one on resume.
        gamecore_setTouchMouseEnabled(settings.touchMouseEnabled)
    }

    private static func logEngineConfigOverlay(
        _ overlayJSON: String,
        container: GameContainer
    ) {
        let logsDir = container.ensureLogsDirectory()
        let path = logsDir.appendingPathComponent("engine-config.log").path
        let line = "engine-config: \(overlayJSON)\n"
        if FileManager.default.fileExists(atPath: path),
            let data = line.data(using: .utf8),
            let handle = FileHandle(forWritingAtPath: path)
        {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
