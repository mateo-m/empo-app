// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

// This stays as a light compatibility wrapper. It keeps the Xcode
// project file unchanged after the update status moved into the
// Settings header.
struct UpdateCheckRow: View {
    let status: UpdateChecker.Status
    let onTapRetry: () -> Void

    var body: some View {
        EmptyView()
    }
}
