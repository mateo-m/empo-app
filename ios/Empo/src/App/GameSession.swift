// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
        let coreSettings = input.core.launch(container)

        crashTracker.writeMarker(for: container)
        let runner = EngineSessionCoordinator.shared.runner
        sessionLogger.beginSession(for: game, container: container, debugLogsEnabled: input.debugLogsEnabled)
        GameReport.last = sessionLogger.logURL.map {
            GameReport(gameTitle: game.title, logURL: $0)
        }
        sessionLogger.note(
            "\(game.title) starts on \(input.core.framework) \(input.core.version), runner \(runner.rawValue)"
        )

        DataDirectory.ensureFontsRoot()
        GameCoreLaunch.configure(
            settings: coreSettings,
            userDataDirectory: input.userDataDir?.path,
            fontsDirectory: DataDirectory.fontsRootURL.path,
            verticalAlignment: alignment.bridgeValue,
            debugLogPath: sessionLogger.logURL?.path)
        // The reset in `configure` cleared the region of the game
        // before. The engine's first layout reads the region, so it
        // goes in before the game starts.
        ScreenRegionApplier.beginSession(container: container)
        // Seed the touch-mouse atomic before boot. The reset in
        // `configure` leaves it alone, so without
        // this the new game inherits the previous game's value until
        // `PlayerRuntimeState.reconcile` runs. That call owns every
        // later push, including the one on resume.
        gamecore_setTouchMouseEnabled(settings.touchMouseEnabled)
    }
}
