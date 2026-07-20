import Foundation
import GameProbe

/// Composes the engine config from `Game/mkxp.json` + the sparse
/// `EmpoState/mkxp.json` overlay and reads developer defaults from
/// `Game/mkxp.json`.
enum EngineConfigProjector {
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        GameConfigDefaults(
            mkxpDefaults: ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
        )
    }

    @discardableResult
    static func composeManagedConfig(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> ComposeResult {
        ManagedMkxpConfig.compose(
            gameDirectory: gameDirectory,
            stateDirectory: stateDirectory
        )
    }

    /// Overlay engine values (JGP import) then compose.
    @discardableResult
    static func applyEngineValues(
        _ values: MkxpEngineValues,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        guard ManagedMkxpConfig.writeOverlay(overrides: values, stateDirectory: stateDirectory)
        else {
            return false
        }
        return ManagedMkxpConfig.compose(
            gameDirectory: gameDirectory,
            stateDirectory: stateDirectory
        ) != .readOnly
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
