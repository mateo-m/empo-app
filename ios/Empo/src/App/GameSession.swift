import Foundation
import GameProbe

/// Owns per-game engine launch: bridge configuration, patch
/// distribution, logging, and the deferred `gamecore_setGamePath` handoff.
@MainActor
enum GameSession {

    struct LaunchInput {
        let game: GameEntry
        let container: GameContainer
        /// Engine-writable data directory (`System.data_directory`),
        /// resolved by `DataDirectory` into the shared
        /// `Documents/Data/<org>/<app>/` tree.
        let userDataDir: URL?
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
        let settings = input.settings
        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment

        // The core reads its settings in gamecore_applySessionConfig.
        input.core.launch(container)

        DataDirectory.ensureFontsRoot()
        func applySessionConfig(userDataDirectory: UnsafePointer<CChar>?) {
            DataDirectory.fontsRootURL.path.withCString { fontsPtr in
                var config = GameCoreSessionConfig()
                config.userDataDirectory = userDataDirectory
                config.sharedFontsDirectory = fontsPtr
                config.verticalAlignment = alignment.bridgeValue
                gamecore_applySessionConfig(&config)
            }
        }
        if let userDataDir = input.userDataDir {
            userDataDir.path.withCString(applySessionConfig(userDataDirectory:))
        } else {
            applySessionConfig(userDataDirectory: nil)
        }

        crashTracker.writeMarker(for: container)
        let runner = EngineSessionCoordinator.shared.runner
        sessionLogger.beginSession(for: game, container: container, debugLogsEnabled: input.debugLogsEnabled)
        GameReport.last = sessionLogger.logURL.map {
            GameReport(gameTitle: game.title, logURL: $0)
        }
        sessionLogger.note(
            "\(game.title) starts on \(input.core.framework) \(input.core.version), runner \(runner.rawValue)"
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
}
