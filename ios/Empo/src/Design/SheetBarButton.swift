// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// A text button in a sheet's top bar. On the closed iPhone Duo, the
/// system moves top-bar buttons into the column under the status bar,
/// but a text-only button stays at the top. There, this button shows
/// its symbol in place of its title.
struct SheetBarButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringResource, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    static func done(action: @escaping () -> Void) -> SheetBarButton {
        SheetBarButton("Done", systemImage: "checkmark", action: action)
    }

    static func cancel(action: @escaping () -> Void) -> SheetBarButton {
        SheetBarButton("Cancel", systemImage: "xmark", action: action)
    }

    var body: some View {
        if #available(iOS 27.1, macOS 27.1, *) {
            VerticalBarButton(title: title, systemImage: systemImage, action: action)
        } else {
            Button(title, action: action)
        }
    }
}

@available(iOS 27.1, macOS 27.1, *)
private struct VerticalBarButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        if verticalEdge == nil {
            Button(title, action: action)
        } else {
            Button(title, systemImage: systemImage, action: action)
                .labelStyle(.iconOnly)
        }
    }
}
