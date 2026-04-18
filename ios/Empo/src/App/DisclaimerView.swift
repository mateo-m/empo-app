import SwiftUI

/// First-launch disclaimer shown over the splash screen. The user must
/// acknowledge it before reaching the library. Co-located with the splash
/// logic in RootView.swift; driven by `AppSettings.needsDisclaimer`.
///
/// The view is pure presentation - it never reads or writes UserDefaults
/// directly. RootView orchestrates the transition and calls
/// `AppSettings.shared.acknowledgeDisclaimer()` when the user taps through.
struct DisclaimerView: View {
    let onAcknowledge: () -> Void

    /// Drives the entry animation (scale + opacity). Starts false, flipped
    /// to true onAppear with a spring, mirroring the splash logo's entrance.
    @State private var entered = false

    var body: some View {
        VStack(spacing: Spacing._2xl) {
            Text("Here be dragons")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("... or bugs! I'm a lone dev building this in my spare time.")
                Text("Things may crash, freeze, or flat-out refuse to load.")
                Text("Save often. Report issues on GitHub if you hit any.")
            }
            .font(.body.weight(.medium))
            .fontDesign(.rounded)
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.leading)
            .lineSpacing(-4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.tap()
                onAcknowledge()
            } label: {
                Text("I understand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DisclaimerButtonStyle())
            .padding(.top, Spacing.lg)
        }
        .padding(.horizontal, Spacing._3xl)
        .scaleEffect(entered ? 1 : 0.97)
        .opacity(entered ? 1 : 0)
        .onAppear {
            withAnimation(Motion.gentle) {
                entered = true
            }
        }
    }
}

/// White capsule button for the orange splash background.
/// Contrasts the brand-colored backdrop with white surface and
/// brand-colored text.
private struct DisclaimerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(Color.brand)
            .padding(.horizontal, Spacing._2xl)
            .padding(.vertical, Spacing.lg)
            .background(.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
