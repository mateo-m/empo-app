// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// The settings a core keeps for itself, next to the shared ones of
/// `GameSettingsModel`. The core makes it with `makeSettings(for:)` and
/// shows it on its own settings page.
@MainActor
protocol CoreSettings: AnyObject {
    var hasCustomizations: Bool { get }
    /// A reset now would race with work that writes the settings.
    var isBusy: Bool { get }
    func save()
    func reset()
}

@MainActor
protocol CoreLaunchedSettings {
    /// The labels of the restart-required settings in `current` that
    /// differ, where `current` came from the same core.
    func restartRequiredChanges(to current: any CoreSettings) -> [String]
}

@MainActor
struct LaunchedSettings {
    let settings: GameSettings
    let core: (any CoreLaunchedSettings)?
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
    #if os(iOS)
    /// The screen placement of the layout profile for each orientation.
    /// A form body renders again on every control change, and the
    /// resolve reads two files.
    var resolvedScreen: ScreenResolution.Result?
    #endif

    init(game: GameEntry) {
        self.game = game
        // The sheet opens only for an entry with a container on disk.
        let container = game.container!
        self.container = container
        ManagedMkxpConfig.migrateDisplaySettingsIfNeeded(stateDirectory: container.empoStateURL)
        let settings = GameSettings.load(from: container.empoStateURL)
        self.settings = settings
        let core = GameCores.core(forGameAt: container.gameURL)
        self.core = core
        self.coreSettings = core?.makeSettings(for: container)
        self.displayDefaults = core?.displayDefaults(for: container) ?? GameDisplayDefaults()
    }

    var hasAnyCustomizations: Bool {
        settings.hasCustomizations || coreSettings?.hasCustomizations == true
    }

    /// Such as "Restart this game to apply: Smooth scaling and Render
    /// scale." Nil when no change waits for a restart.
    func restartHint(since launched: LaunchedSettings) -> LocalizedStringResource? {
        var changed = settings.restartRequiredFieldsChanged(from: launched.settings)
        if let coreSettings, let launchedCore = launched.core {
            changed += launchedCore.restartRequiredChanges(to: coreSettings)
        }
        guard !changed.isEmpty else { return nil }
        let list = changed.formatted(.list(type: .and, width: .standard))
        return LocalizedStringResource(
            "Restart this game to apply: \(list).",
            comment:
                "The placeholder is a list of setting names, such as \"Smooth scaling and Render scale\".")
    }

    func save() {
        settings.save(to: container.empoStateURL)
        coreSettings?.save()
    }

    func resetToDefaults() {
        settings = GameSettings()
        coreSettings?.reset()
    }

    #if os(iOS)
    func reloadResolvedScreen() {
        let store = LayoutProfilesManager.store
        resolvedScreen = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { store.readScreen($0) }
        )
    }
    #endif

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
        FastForwardArbiter.usableMultiplier(settings.speedMultiplier) != nil
    }
    /// The slider value. 4x while fast forward is off, so turning the
    /// toggle on lands on a useful speed.
    var effectiveSpeedMultiplier: Int {
        max(2, min(9, settings.speedMultiplier ?? 4))
    }
}
