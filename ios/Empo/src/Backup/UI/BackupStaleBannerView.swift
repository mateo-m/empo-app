import GameProbe
import SwiftUI

/// The one library banner of SPEC 7.1, at 21 days.
///
/// One banner covers the library, not one per game. It names the
/// cause and carries the single action that fixes it.
struct BackupStaleBannerView: View {

    let banner: LibraryStaleBanner
    let targetLabel: String?
    var onAct: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.warning)

            Text(banner.line(targetLabel: targetLabel))
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(banner.action.label, action: onAct)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}
