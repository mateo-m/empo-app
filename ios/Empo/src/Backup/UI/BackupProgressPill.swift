import GameProbe
import SwiftUI

/// The progress pill of SPEC 13.2.
///
/// It floats at the bottom of the library, above the update banner.
/// A tap opens the Backups screen at the run block.
struct BackupProgressPill: View {

    var onTap: () -> Void

    private var monitor: BackupRunMonitor { BackupRunMonitor.shared }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                // The ZStacks hold the old and the new view on one spot
                // while they cross-fade, so the capsule grows or shrinks
                // to the new text instead of holding both side by side.
                ZStack { mark.transition(.fadeBlur) }
                ZStack {
                    Text(monitor.line)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .id(monitor.line)
                        .transition(.fadeBlur)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .geometryGroup()
            .glassEffect(.regular, in: .capsule)
            .animation(Motion.standard, value: monitor.line)
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
        case .stopped:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.warning)
        case .checking, .uploading:
            // The plan freezes only as the hashes land, so the ring
            // spins until the first stream reports its total.
            SpinnerRing(
                progress: monitor.fraction ?? 0,
                size: 14,
                lineWidth: 2,
                tint: AnyShapeStyle(Color.brand),
                trackOpacity: 0.2)
        }
    }
}
