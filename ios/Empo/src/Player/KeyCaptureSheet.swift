import GameProbe
import SwiftUI

/// "Press the button you want to use" step of the keyboard rows.
///
/// A controller in keyboard mode sends a key per button, and no list
/// can say which. The player presses the button; Empo reads the key.
struct KeyCaptureSheet: View {
    var keyboardInput: KeyboardInputManager
    let onCapture: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "keyboard")
                    .font(.system(size: 44))
                    .foregroundStyle(.brand)
                Text("Press a button")
                    .font(.title3.weight(.semibold))
                Text(
                    """
                    Press the button on your controller, or the key on your keyboard, \
                    that you want to bind.
                    """
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Add a key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            keyboardInput.keyActivityHandler = { code in
                onCapture(code)
            }
        }
        .onDisappear {
            // The remap screen puts its own highlight handler back
            // when it reappears; clearing here keeps a dismissed
            // sheet from binding a stray key.
            keyboardInput.keyActivityHandler = nil
        }
    }
}
