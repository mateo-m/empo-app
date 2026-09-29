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
    let displayDefaults: GameDisplayDefaults
    /// The screen placement of the layout profile for each orientation.
    /// A form body renders again on every control change, and the
    /// resolve reads two files.
    var resolvedScreen: ScreenResolution.Result?

    @ObservationIgnored private let initialSettings: GameSettings

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
        self.settings = settings
        self.initialSettings = settings
        let core = GameCores.core(forGameAt: container.gameURL)
        self.core = core
        self.coreSettings = core?.makeSettings(for: container)
        self.displayDefaults = core?.displayDefaults(for: container) ?? GameDisplayDefaults()
    }

    var hasAnyCustomizations: Bool {
        settings.hasCustomizations || coreSettings?.hasCustomizations == true
    }

    var restartRequiredChanges: [String] {
        settings.restartRequiredFieldsChanged(from: initialSettings)
            + (coreSettings?.restartRequiredChanges ?? [])
    }

    func save() {
        settings.save(to: container.empoStateURL)
        coreSettings?.save()
    }

    func resetToDefaults() {
        settings = GameSettings()
        coreSettings?.reset()
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
        settings.smoothScaling ?? displayDefaults.smoothScaling ?? GameConfigDefaults.engineSmoothScaling
    }
    var effectiveFixedAspectRatio: Bool {
        settings.fixedAspectRatio ?? displayDefaults.fixedAspectRatio
            ?? GameConfigDefaults.engineFixedAspectRatio
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
