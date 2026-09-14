import SwiftUI

/// "Press the button you want to use" step of the keyboard rows.
///
/// A controller in keyboard mode sends a key per button, and no list
/// can say which. The player presses the button. The bindings screen
/// reads the key and moves on to the target picker.
struct KeyCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: "Press a button",
            emblem: "keyboard",
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(
                "Press the controller button or keyboard key you want to bind."
            )
        }
    }
}
