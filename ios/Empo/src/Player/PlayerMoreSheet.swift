import SwiftUI

/// Bottom sheet of secondary in-game actions reachable from the
/// player toolbar's "More" button. Houses options that don't earn a
/// permanent toolbar slot — pause, cheats, debug overlay, fast
/// forward, quit. Toggles update host state directly; tap actions
/// dismiss the sheet via `dismiss()` so the user lands back in the
/// game.
struct PlayerMoreSheet: View {
    @Binding var showDebugOverlay: Bool
    @Binding var fastForwardActive: Bool
    let onPause: () -> Void
    let onCheats: () -> Void
    let onQuit: () -> Void

    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if settings.isEnabled(.gamePause) {
                    rowAction(
                        icon: "pause.fill",
                        label: "Pause",
                        action: { onPause(); dismiss() }
                    )
                }

                if settings.isEnabled(.cheats) {
                    rowAction(
                        icon: "wand.and.stars",
                        label: "Cheats menu",
                        action: { onCheats(); dismiss() }
                    )
                }

                rowToggle(
                    icon: "hare.fill",
                    label: "Fast forward",
                    isOn: $fastForwardActive
                )

                if settings.debugMode {
                    rowToggle(
                        icon: "ladybug.fill",
                        label: "Debug overlay",
                        isOn: $showDebugOverlay
                    )
                }

                if settings.isEnabled(.gameQuit) {
                    rowAction(
                        icon: "xmark.circle.fill",
                        label: "Quit game",
                        tint: .red,
                        action: { dismiss(); onQuit() }
                    )
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func rowAction(icon: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(label).foregroundStyle(tint)
                } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func rowToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            // Match the icon color to the label text color so the
            // toggle row reads as one unit. By default a Label inside
            // a Toggle paints its icon with the tint accent (blue),
            // which clashes with the .primary text - non-destructive
            // rows look more cohesive when both share .primary.
            Label {
                Text(label)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.primary)
            }
        }
    }
}
