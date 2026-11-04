// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

// GameProbe also builds on Linux, so its text stays English there. The
// compiler can't extract a key that is only known at run time, so
// Localizable.xcstrings holds these keys as manual entries.
extension EmpoAction {
    var localizedName: String { String(localized: String.LocalizationValue(displayName)) }
    var localizedBlurb: String { String(localized: String.LocalizationValue(blurb)) }
}

extension KeyCodePickerGroup {
    var localizedTitle: String {
        String(localized: String.LocalizationValue(KeyCodeTable.pickerGroupTitle(self)))
    }
}
