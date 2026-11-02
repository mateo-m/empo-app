// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

@MainActor
@Observable
final class PressedRowHighlight {
    private(set) var rowID: String?
    @ObservationIgnored private var clear: Task<Void, Never>?

    func flash(_ rowID: String) {
        self.rowID = rowID
        clear?.cancel()
        clear = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.rowID = nil
        }
    }

    func background(for rowID: String) -> Color? {
        self.rowID == rowID ? Color.brand.opacity(0.15) : nil
    }
}

extension View {
    /// Scrolls to the row of each press. Each row needs `.id(row.id)`.
    func scrollsToPressedRow(_ highlight: PressedRowHighlight, with proxy: ScrollViewProxy) -> some View {
        onChange(of: highlight.rowID) { _, row in
            guard let row else { return }
            withAnimation(Motion.snappy) {
                proxy.scrollTo(row, anchor: .center)
            }
        }
    }
}
