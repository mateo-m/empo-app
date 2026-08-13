import SwiftUI

/// "Press the button you want to use" step of the keyboard rows.
///
/// A controller in keyboard mode sends a key per button, and no list
/// can say which. The player presses the button; the bindings screen
/// reads the key and moves on to the target picker.
struct KeyCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: "Press a Button",
            emblem: "keyboard",
            trailingButton: ("Cancel", { dismiss() })
        ) {
            SheetProse(
                "Press the button on your controller, or the key on your "
                    + "keyboard, that you want to bind."
            )
        }
    }
}
