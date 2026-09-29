import Foundation
import GameProbe

/// Reads developer defaults from `Game/mkxp.json` and writes the
/// settings overlay.
enum EngineConfigProjector {
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        GameConfigDefaults(
            mkxpDefaults: ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
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
