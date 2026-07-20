import Foundation
import GameProbe

/// Merges `GameSettings` overrides into the per-game managed
/// `EmpoState/mkxp.json` and reads developer defaults from
/// `Game/mkxp.json`.
enum EngineConfigProjector {
    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        GameConfigDefaults(
            mkxpDefaults: ManagedMkxpConfig.readGameDefaults(from: gameDirectory)
        )
    }

    /// One-time import seed: copy `Game/mkxp.json` into the managed
    /// config with projector normalizations. Does not regenerate on
    /// every boot.
    @discardableResult
    static func seedManagedConfig(
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        ManagedMkxpConfig.seed(from: gameDirectory, to: stateDirectory)
    }

    /// Overlay engine values onto the managed config (JGP import).
    @discardableResult
    static func applyEngineValues(
        _ values: MkxpEngineValues,
        stateDirectory: URL,
        gameDirectory: URL
    ) -> Bool {
        ManagedMkxpConfig.project(
            devBaseFrom: gameDirectory,
            overrides: values,
            to: stateDirectory
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
