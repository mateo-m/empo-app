import SwiftUI

/// Opt-in confirmation sheet for experimental features.
///
/// Used when the user flips an experimental toggle or picks the ANGLE
/// renderer. Presents an "are you sure?" affirmation with an inverted
/// background (light in dark mode, dark in light mode) so the sheet
/// reads as a distinct moment separated from the surrounding Settings
/// form.
///
/// The sheet is pure presentation: the caller owns the binding that
/// drives presentation and supplies the two handlers.
struct ExperimentalConfirmSheet: View {
    let title: String
    let message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExperimentalSheetScaffold {
            // Chip + title grouped tightly
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "flask.fill")
                    Text("Experimental")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.brand)

                Text("Enable \"\(title)\"?")
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(ExperimentalSheetPalette.foreground(for: colorScheme))
            }

            Text(message)
                .font(.body.weight(.medium))
                .foregroundStyle(ExperimentalSheetPalette.secondaryForeground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

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
