import SwiftUI

/// First-launch disclaimer shown over the splash screen. The user must
/// acknowledge it before the library appears. It lives with the splash
/// logic in RootView.swift. `AppSettings.needsDisclaimer` drives it.
///
/// The view is pure presentation. It never reads or writes UserDefaults
/// directly. RootView runs the transition and calls
/// `AppSettings.shared.acknowledgeDisclaimer()` when the user taps through.
struct DisclaimerView: View {
    let onAcknowledge: () -> Void

    /// Drives the entry animation (scale + opacity). Starts false.
    /// onAppear flips it to true with a spring, which mirrors the
    /// splash logo's entrance.
    @State private var entered = false

    /// The "Save often..." line as an AttributedString, so the GitHub
    /// link can be both bold AND underlined. Markdown's `**bold**`
    /// alone is not visually distinct against the white-on-orange
    /// copy.
    private var githubReportLine: AttributedString {
        var attr =
            (try? AttributedString(
                markdown: "Save often. If you hit issues, report them on [**GitHub**](\(GitInfo.issuesURL))."
            )) ?? AttributedString("Save often. If you hit issues, report them on GitHub.")
        for run in attr.runs where run.link != nil {
            attr[run.range].underlineStyle = .single
        }
        return attr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing._2xl) {
            VStack(spacing: 0) {
                Text("Here be dragons")
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.rounded)
                Text("or bugs!")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("I am a lone dev who builds this in my spare time.")
                Text("Things can crash, freeze, or refuse to load.")
                // The build generates the URL from the git origin
                // (see project.yml's "Generate Git Info" phase).
                // The disclaimer thus always points at the fork
                // someone builds.
                Text(githubReportLine)
                    .tint(.white)
                Text("Enjoy!")
                    .padding(.top, Spacing.md)
                Text("Grid.")
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
/// Contrasts the brand-colored backdrop with a white surface and
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
