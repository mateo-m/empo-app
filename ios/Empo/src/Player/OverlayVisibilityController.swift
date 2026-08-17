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
    private var hiddenBinding: Binding<Bool>?
    private var editModeBinding: Binding<Bool>?

    func bind(hidden: Binding<Bool>, editMode: Binding<Bool>) {
        state = OverlayVisibility()
        hiddenBinding = hidden
        editModeBinding = editMode
    }

    func unbind() {
        hiddenBinding = nil
        editModeBinding = nil
    }

    /// Records a fact, then applies the rule. Edit mode keeps the
    /// overlay on screen whatever the facts say, because the player
    /// is arranging it.
    func update(_ change: (inout OverlayVisibility) -> Void) {
        change(&state)
        guard editModeBinding?.wrappedValue != true else { return }
        guard let hiddenBinding, let hidden = state.hidden else { return }
        if hiddenBinding.wrappedValue != hidden {
            hiddenBinding.wrappedValue = hidden
        }
    }
}
