// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Starts a game on the open core. The iOS app and Empo Player both use
/// it, so the cores get the same calls in the same order everywhere.
enum GameCoreLaunch {
    /// Prepares the core for the next game: the debug log, the settings
    /// of the game, and the session config. Then it clears the state of
    /// the game before.
    static func configure(
        settings: [CoreSetting],
        userDataDirectory: String?,
        fontsDirectory: String,
        verticalAlignment: GameCoreVerticalAlignment,
        debugLogPath: String?
    ) {
        gamecore_setDebugLogPath(debugLogPath)
        for setting in settings {
            gamecore_setSetting(setting.key, setting.value)
        }
        // The core reads its settings in gamecore_applySessionConfig.
        func apply(userData: UnsafePointer<CChar>?) {
            fontsDirectory.withCString { fonts in
                var config = GameCoreSessionConfig(
                    userDataDirectory: userData, sharedFontsDirectory: fonts,
                    verticalAlignment: verticalAlignment)
                gamecore_applySessionConfig(&config)
            }
        }
        if let userDataDirectory {
            userDataDirectory.withCString(apply(userData:))
        } else {
            apply(userData: nil)
        }
        gamecore_resetSessionState()
        // The launcher reads the game controllers and sends their keys.
        gamecore_setGameControllerCaptureEnabled(false)
    }

    /// Call it from a run loop callout on the main thread, never from a
    /// block on the main dispatch queue (GameCore.h).
    static func run(gamePath: String) {
        gamecore_setGamePath(gamePath)
        _ = gamecore_run_app(1, argv)
    }

    // PSDK's Ruby keeps argv and reads argv[0] for its own paths
    // (psdk_core.h). The other arguments are not for a game. The game
    // process gives its own argv[0] in GameProcessService.m.
    nonisolated(unsafe) private static let argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        argv[0] = CommandLine.unsafeArgv[0]
        argv[1] = nil
        return argv
    }()
}
