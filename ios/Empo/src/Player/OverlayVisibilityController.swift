// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// Holds the session's `OverlayVisibility` facts and writes the one
/// binding the player sees.
///
/// The input managers report what happened. The rule in GameProbe
/// decides. Neither manager touches `controlsHidden` itself.
@MainActor
final class OverlayVisibilityController {
    private var state = OverlayVisibility()
    private var player: (hidden: Binding<Bool>, editMode: () -> Bool)?

    func bind(hidden: Binding<Bool>, editMode: @escaping () -> Bool) {
        state = OverlayVisibility()
        player = (hidden, editMode)
    }

    func unbind() {
        player = nil
    }

    /// Records a fact, then applies the rule. Edit mode keeps the
    /// overlay on screen whatever the facts say, because the player
    /// is arranging it.
    func update(_ change: (inout OverlayVisibility) -> Void) {
        change(&state)
        guard let player, !player.editMode(), let hidden = state.hidden else { return }
        if player.hidden.wrappedValue != hidden {
            player.hidden.wrappedValue = hidden
        }
    }
}
