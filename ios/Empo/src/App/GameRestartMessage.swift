// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

func getGameRestartMessage(atTitle: Bool) -> String {
    atTitle
        ? String(
            localized: "The game stopped and restarted at the title screen. Any saves you made are safe.")
        : String(
            localized:
                "The game stopped and restarted from an earlier point. You may need to replay the last few minutes."
        )
}
