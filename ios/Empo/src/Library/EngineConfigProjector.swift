import Foundation
import GameProbe

/// Reads developer defaults from `Game/mkxp.json` and builds the in-
/// memory config overlay string for the engine bridge.
enum EngineConfigProjector {
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        GameConfigDefaults(
            mkxpDefaults: ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
        )
    }

    static func overlayJSONString(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> String? {
        ManagedMkxpConfig.overlayJSONString(
            gameDirectory: gameDirectory,
            stateDirectory: stateDirectory,
            onUnparseableOverlay: { NSLog($0) }
        )
    }

    @discardableResult
    static func applyEngineValues(
        _ values: MkxpEngineValues,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        _ = gameDirectory
        return ManagedMkxpConfig.writeOverlay(
            overrides: values,
            stateDirectory: stateDirectory
        )
    }

    static func migrateLegacyEngineSettingsIfNeeded(
        stateDirectory: URL,
        gameDirectory: URL
    ) {
        _ = ManagedMkxpConfig.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: stateDirectory,
            gameDirectory: gameDirectory
        )
    }
}
