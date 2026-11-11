// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/// One `gamecore_setSetting` call. The keys are the `GAMECORE_SETTING_*`
/// names of GameCore.h.
struct CoreSetting: Codable, Equatable {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    init(_ key: String, _ on: Bool) {
        self.init(key, on ? "1" : "0")
    }
}
