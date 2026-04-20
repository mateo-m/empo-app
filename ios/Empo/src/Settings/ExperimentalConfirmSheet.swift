import SwiftUI

/// Opt-in confirmation sheet for experimental features.
///
/// Used when the user flips an experimental toggle or picks the ANGLE
/// renderer. The sheet is pure presentation: the caller owns the
/// binding that drives presentation and supplies the two handlers.
struct ExperimentalConfirmSheet: View {
    let title: String
    let message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExperimentalSheetScaffold(
            title: "Enable \"\(title)\"?",
            caption: .init("Experimental", systemImage: "flask.fill"),
            message: message
        ) {
            VStack(spacing: Spacing.md) {
                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Enable")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)

                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondary)
            }
        }
    }
}
