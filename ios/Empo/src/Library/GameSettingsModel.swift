import GameProbe
import SwiftUI

/// The settings a core keeps for itself, next to the shared ones of
/// `GameSettingsModel`. The core makes it with `makeSettings(for:)` and
/// shows it on its own settings page.
@MainActor
protocol CoreSettings: AnyObject {
    var hasCustomizations: Bool { get }
    /// The labels of the restart-required settings the user changed
    /// since the sheet opened.
    var restartRequiredChanges: [String] { get }
    func save()
    func reset()
}

/// The state of the Game Settings sheet for one game.
@MainActor @Observable
final class GameSettingsModel {
    let game: GameEntry
    let container: GameContainer
    let core: (any GameCore)?
    let coreSettings: (any CoreSettings)?

    var settings: GameSettings
    var engineSettings: EngineMkxpSettings
    private(set) var defaults: GameConfigDefaults
    /// The screen placement of the layout profile for each orientation.
    /// A form body renders again on every control change, and the
    /// resolve reads two files.
    var resolvedScreen: ScreenResolution.Result?

    @ObservationIgnored private let initialSettings: GameSettings
    @ObservationIgnored private let initialEngineSettings: EngineMkxpSettings

    var gameDirectory: URL { container.gameURL }
    var stateDirectory: URL { container.empoStateURL }

    init(game: GameEntry) {
        self.game = game
        // The sheet opens only for an entry with a container on disk.
        let container = game.container!
        self.container = container
        GameSettings.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: container.empoStateURL,
            gameDirectory: container.gameURL
        )
        let settings = GameSettings.load(from: container.empoStateURL)
        let engine = EngineMkxpSettings.load(
            from: container.empoStateURL, gameDirectory: container.gameURL)
        self.settings = settings
        self.engineSettings = engine
        self.defaults = GameSettings.readGameDefaults(from: container.gameURL)
        self.initialSettings = settings
        self.initialEngineSettings = engine
        let core = GameCores.core(forGameAt: container.gameURL)
        self.core = core
        self.coreSettings = core?.makeSettings(for: container)
    }

    var hasAnyCustomizations: Bool {
        settings.hasCustomizations || engineSettings.hasOverrides(devDefaults: defaults)
            || coreSettings?.hasCustomizations == true
    }

    var restartRequiredChanges: [String] {
        settings.restartRequiredFieldsChanged(from: initialSettings)
            + engineSettings.restartRequiredFieldsChanged(from: initialEngineSettings)
            + (coreSettings?.restartRequiredChanges ?? [])
    }

    func save() {
        settings.save(to: stateDirectory)
        engineSettings.save(to: stateDirectory, gameDirectory: gameDirectory)
        coreSettings?.save()
    }

    func resetToDefaults() {
        settings = GameSettings()
        defaults = GameSettings.readGameDefaults(from: gameDirectory)
        engineSettings.resetToDefaults(gameDirectory: gameDirectory, stateDirectory: stateDirectory)
        coreSettings?.reset()
    }

    func resetEngineField(_ field: MkxpEngineField) {
        engineSettings.resetField(field, gameDirectory: gameDirectory, stateDirectory: stateDirectory)
    }

    func reloadResolvedScreen() {
        let store = LayoutProfilesManager.store
        resolvedScreen = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { store.readScreen($0) }
        )
    }

    // MARK: - Effective values

    var effectiveSmoothScaling: Bool {
        engineSettings.smoothScaling ?? defaults.smoothScaling ?? GameConfigDefaults.engineSmoothScaling
    }
    var effectiveFixedAspectRatio: Bool {
        engineSettings.fixedAspectRatio ?? defaults.fixedAspectRatio
            ?? GameConfigDefaults.engineFixedAspectRatio
    }
    var effectiveFrameSkip: Bool {
        engineSettings.frameSkip ?? defaults.frameSkip ?? GameConfigDefaults.engineFrameSkip
    }
    var effectiveFontScale: Double {
        engineSettings.fontScale ?? defaults.fontScale ?? GameConfigDefaults.engineFontScale
    }
    var effectivePathCache: Bool {
        engineSettings.pathCache ?? defaults.pathCache ?? GameConfigDefaults.enginePathCache
    }
    var effectiveSolidFonts: Bool {
        engineSettings.solidFonts ?? defaults.solidFonts ?? GameConfigDefaults.engineSolidFonts
    }
    var effectiveRenderScale: RenderScale {
        engineSettings.renderScale ?? defaults.renderScale ?? GameConfigDefaults.engineRenderScale
    }
    /// Fast forward is on when the user set a multiplier of 2 or more.
    var fastForwardEnabled: Bool {
        (settings.speedMultiplier ?? 0) >= 2
    }
    /// The slider value. 4x while fast forward is off, so turning the
    /// toggle on lands on a useful speed.
    var effectiveSpeedMultiplier: Int {
        max(2, min(9, settings.speedMultiplier ?? 4))
    }
}
