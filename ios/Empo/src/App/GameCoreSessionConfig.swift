// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

extension GameCoreSessionConfig {
    /// Gives `apply` a config whose C strings stay valid during the call.
    static func with(
        userDataDirectory: String?,
        sharedFontsDirectory: String,
        verticalAlignment: GameCoreVerticalAlignment,
        _ apply: (UnsafePointer<GameCoreSessionConfig>) -> Void
    ) {
        func applyConfig(userData: UnsafePointer<CChar>?) {
            sharedFontsDirectory.withCString { fonts in
                var config = GameCoreSessionConfig(
                    userDataDirectory: userData, sharedFontsDirectory: fonts,
                    verticalAlignment: verticalAlignment)
                apply(&config)
            }
        }
        if let userDataDirectory {
            userDataDirectory.withCString(applyConfig(userData:))
        } else {
            applyConfig(userData: nil)
        }
    }
}
