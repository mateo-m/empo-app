// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Observation

/// The prompts the library opens on its own, without a tap.
///
/// SwiftUI drops a sheet that opens while another one is up or still
/// animating out, so they open one at a time, in the order of `Kind`.
/// A sheet calls `done` from its `onDismiss`, which runs after the
/// dismissal animation.
@MainActor
@Observable
final class LaunchPrompts {

    enum Kind: Int, Comparable {
        case duplicateGames, saveRecovery, packageImport, resumeQuestion, whatsNew

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var waiting: Set<Kind> = []
    private(set) var showing: Kind?

    func wait(_ kind: Kind) {
        waiting.insert(kind)
        advance()
    }

    func done(_ kind: Kind) {
        waiting.remove(kind)
        if showing == kind { showing = nil }
        advance()
    }

    private func advance() {
        guard showing == nil else { return }
        showing = waiting.min()
    }
}
