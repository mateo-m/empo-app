import SwiftUI

/// Educational sheet triggered when the user taps the small flask
/// icon next to an experimental setting row. Explains what the marker
/// means so users can decide whether to enable the feature before
/// hitting the confirmation flow.
///
/// Shares the native `NavigationStack` + principal-toolbar layout
/// with `ExperimentalConfirmSheet` so the two read as a family.
struct ExperimentalInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var measuredHeight: CGFloat = 0
    private let chromeAllowance: CGFloat = 64

    var body: some View {
        NavigationStack {
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing._2xl)
            .padding(.vertical, Spacing._2xl)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                measuredHeight = newHeight
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("What's this?")
                            .font(.headline)
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "flask.fill")
                                .font(.system(size: 9))
                            Text("Experimental")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.brand)
                    }
                    .sheetTitle()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .tint(.brand)
                }
            }
        }
        .presentationDetents(
            measuredHeight > 0
                ? [.height(measuredHeight + chromeAllowance)]
                : [.medium]
        )
        .presentationDragIndicator(.visible)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.brand)
                .padding(.top, Spacing.sm)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
