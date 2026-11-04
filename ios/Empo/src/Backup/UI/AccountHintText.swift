import GameProbe
import SwiftUI
import UIKit

/// The account hint, with the person's name hidden until a tap.
struct AccountHintText: View {

    let hint: String
    let provider: BackupProviderKind

    @State private var isShown = false

    var body: some View {
        if let masked = AccountHintMask.masked(hint, provider: provider) {
            TappableLine(
                text: isShown ? hint : masked,
                accessibilityText: isShown ? hint : "Account hidden",
                accessibilityHint: isShown ? "Hides the account" : "Shows the account"
            ) { isShown.toggle() }
            // A list row merges this line into its own element, which
            // hides the label's activation from VoiceOver.
            .accessibilityAction(named: isShown ? "Hide account" : "Show account") {
                isShown.toggle()
            }
        } else {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// SwiftUI grows a small tap target to a finger's size, and in a
/// location row that reaches the name and the status line. A UIKit
/// tap only answers inside the drawn text.
private struct TappableLine: UIViewRepresentable {

    let text: String
    let accessibilityText: String
    let accessibilityHint: String
    let tap: () -> Void

    func makeUIView(context: Context) -> Label {
        let label = Label()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.isUserInteractionEnabled = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.addGestureRecognizer(
            UITapGestureRecognizer(target: label, action: #selector(Label.tapped)))
        return label
    }

    func updateUIView(_ label: Label, context: Context) {
        label.text = text
        label.accessibilityLabel = accessibilityText
        label.accessibilityHint = accessibilityHint
        label.accessibilityTraits = .button
        label.tap = tap
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Label, context: Context) -> CGSize? {
        let fit = uiView.sizeThatFits(
            CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: min(fit.width, proposal.width ?? fit.width), height: fit.height)
    }

    final class Label: UILabel {
        var tap: () -> Void = {}

        @objc func tapped() { tap() }

        override func accessibilityActivate() -> Bool {
            tap()
            return true
        }
    }
}
