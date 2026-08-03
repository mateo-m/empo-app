import Foundation
import GameProbe

/// Owns per-game engine launch: bridge configuration, patch
/// distribution, logging, and the deferred `mkxp_setGamePath` handoff.
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
        var settings: GameSettings
        var metadata: GameMetadata
        let debugLogsEnabled: Bool
    }

    /// Apply managed dirs, Ruby dispatch, syntax transform, patches,
    /// session logging, and bridge session config. Does not set
    /// `mkxp_setGamePath`. The caller awaits engine termination first.
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
        let metadata = input.metadata

        let syntaxTransform = settings.resolveSyntaxTransformMode(
            gameDirectory: gameDir,
            autoDetectedModern: metadata.modernRubyScriptsDetected
        )
        let rubyVersionRaw = settings.rubyVersionOverride ?? metadata.rubyVersion
        let rubyVer: MKXPRubyVersion = {
            switch rubyVersionRaw {
            case 18?: return MKXP_RUBY_18
            case 19?: return MKXP_RUBY_19
            case 30?, 31?: return MKXP_RUBY_31
            default: return MKXP_RUBY_UNSET
            }
        }()

        let alignment = settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
        let postload = settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
        let inGameKeyboardDefault = PokemonEssentialsDetection.detect(
            in: gameDir,
            stateDirectory: stateDir
        )

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
            overlayJSON.withCString { mkxp_setConfigOverlayJSON($0) }
            logEngineConfigOverlay(overlayJSON, container: container)
        } else {
            mkxp_setConfigOverlayJSON(nil)
        }

        // Never point managedConfigDir at EmpoState. The sparse
        // overlay mkxp.json there is not a complete config. If the
        // engine read it as base, it would drop every dev key from
        // Game/mkxp.json.
        "".withCString { managedPtr in
            input.userDataDir.path.withCString { userDataPtr in
                var config = MKXPSessionConfig()
                config.managedConfigDir = managedPtr
                config.userDataDirectory = userDataPtr
                config.rubyVersion = rubyVer
                config.syntaxTransformMode = syntaxTransform
                config.verticalAlignment = alignment.bridgeValue
                config.postloadEnabled = postload
                config.useInGameKeyboard = settings.useInGameKeyboard ?? inGameKeyboardDefault
                config.joiplayCompat = settings.joiplayCompat ?? false
                config.networkEnabled = settings.networkEnabled ?? true
                mkxp_applySessionConfig(&config)
            }
        }

        crashTracker.writeMarker(for: container)
        sessionLogger.beginSession(
            for: game,
            container: container,
            debugLogsEnabled: input.debugLogsEnabled
        )

        mkxp_resetSessionState()
        mkxp_setGameControllerCaptureEnabled(false)
        mkxp_setTouchMouseEnabled(settings.touchMouse ?? true)
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

    static func refreshMetadataIfNeeded(
        settings: GameSettings,
        metadata: inout GameMetadata,
        container: GameContainer,
        forceRefresh: Bool
    ) {
        guard settings.allowsRubyAutoDetectRefresh else { return }
        metadata.refreshDetectedProfile(in: container, forceRefresh: forceRefresh)
    }
}
