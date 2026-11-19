// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

extension View {
    @ViewBuilder
    func navigationBackground(_ style: some ShapeStyle) -> some View {
        if #available(iOS 18.0, *) {
            containerBackground(style, for: .navigation)
        } else {
            self
        }
    }
}
