// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

extension View {
    /// The scene modifier `restorationBehavior(.disabled)` needs macOS 15.
    func windowNotRestored() -> some View {
        background(NotRestoredWindow())
    }
}

private struct NotRestoredWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowHook: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isRestorable = false
    }
}
