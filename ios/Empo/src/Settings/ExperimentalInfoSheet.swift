import SwiftUI

/// Educational sheet triggered when the user taps the small flask
/// icon next to an experimental setting row. Explains what the marker
/// means so users can decide whether to enable the feature before
/// hitting the confirmation flow.
///
/// Shares the inverted-scheme scaffold with `ExperimentalConfirmSheet`
/// so the two read as a coherent family.
struct ExperimentalInfoSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExperimentalSheetScaffold {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "flask.fill")
                    Text("Experimental")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.brand)

                Text("What's this?")
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(ExperimentalSheetPalette.foreground(for: colorScheme))
            }

            VStack(alignment: .leading, spacing: Spacing.lg) {
                bulletRow(
                    "Experimental features are works in progress."
                )
                bulletRow(
                    "They may crash, misbehave, or change without warning."
                )
                bulletRow(
                    "Enabling one doesn't commit you: you can toggle it off any time."
                )
                bulletRow(
                    "If something breaks while one is on, disable it and see if the problem goes away."
                )
            }
            .font(.body.weight(.medium))
            .foregroundStyle(ExperimentalSheetPalette.secondaryForeground(for: colorScheme))

            Button {
                dismiss()
            } label: {
                Text("Got it")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.brand)
                .padding(.top, 6)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
