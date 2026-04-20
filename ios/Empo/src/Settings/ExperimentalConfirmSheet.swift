import SwiftUI

/// Opt-in confirmation sheet for experimental features.
///
/// Used when the user flips an experimental toggle or picks the ANGLE
/// renderer. Uses the native `NavigationStack` + inline-title pattern
/// with a principal toolbar slot that renders the title plus an
/// "Experimental" subtitle chip - same composition as GameInfoView.
/// The sheet cannot be dismissed by tapping the backdrop; the user
/// must pick Enable or Cancel.
struct ExperimentalConfirmSheet: View {
    let title: String
    let message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Height of the sheet's own intrinsic content, captured via
    /// `onGeometryChange`. Drives the presentation detent so the sheet
    /// sits at exactly the height its content needs.
    @State private var measuredHeight: CGFloat = 0

    /// Rough allowance for the navigation bar + drag indicator so the
    /// measured content doesn't clip when baked into the detent.
    private let chromeAllowance: CGFloat = 64

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing._3xl) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Enable")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
            }
            .padding(.horizontal, Spacing._2xl)
            .padding(.vertical, Spacing._2xl)
            // Force intrinsic height so the geometry reader measures the
            // actual content, not the proposed full-sheet height.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
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
                        Text("Enable \"\(title)\"?")
                            .font(.headline)
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "flask.fill")
                                .font(.system(size: 9))
                            Text("Experimental")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.brand)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
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
}
