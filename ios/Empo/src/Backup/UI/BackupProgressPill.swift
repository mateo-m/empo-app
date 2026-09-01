import GameProbe
import SwiftUI

/// The progress pill of SPEC 13.2.
///
/// It pins under the navigation bar in the library. The update
/// banner owns the bottom safe-area inset, so the two never compete.
/// A tap opens the Backups screen at the run block.
struct BackupProgressPill: View {

    var onTap: () -> Void

    private var monitor: BackupRunMonitor { BackupRunMonitor.shared }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                mark
                Text(monitor.line)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(monitor.line)
    }

    @ViewBuilder
    private var mark: some View {
        switch monitor.phase {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.brand)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .preparing, .uploading:
            // The plan freezes only as the hashes land, so the ring
            // spins until the first stream reports its total.
            SpinnerRing(
                progress: monitor.plan.fraction ?? 0,
                size: 14,
                lineWidth: 2,
                tint: AnyShapeStyle(Color.brand),
                trackOpacity: 0.2)
        }
    }
}
