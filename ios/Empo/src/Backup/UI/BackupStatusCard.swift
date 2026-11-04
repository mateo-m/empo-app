import GameProbe
import SwiftUI

/// The card at the top of the Backups screen, per SPEC 13.4.
///
/// One symbol, one headline, one line under it. While a run moves,
/// the ring spins until the run knows its size, then fills, and the
/// run line takes the second row. The ring turns into the checkmark
/// when the run ends.
struct BackupStatusCard: View {

    let status: BackupsScreenStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var symbolSide: CGFloat = 32

    private var monitor: BackupRunMonitor { BackupRunMonitor.shared }

    private enum Mark: Equatable {
        case running, pausedRun, ready, healthy, paused, problem
    }

    private var mark: Mark {
        if monitor.isRunning {
            if case .paused = monitor.phase { return .pausedRun }
            return .running
        }
        if status.isHealthy {
            return status.line == BackupsScreenStatusRules.readyLine ? .ready : .healthy
        }
        return status.targetId == nil ? .paused : .problem
    }

    private var headline: String {
        switch mark {
        case .running: return "Backing up"
        case .pausedRun: return "Backup paused"
        case .ready, .healthy, .paused, .problem: return status.line
        }
    }

    private var detail: String? {
        switch mark {
        case .running, .pausedRun: return monitor.line
        case .ready, .healthy, .paused, .problem: return status.detail
        }
    }

    private var swap: AnyTransition { reduceMotion ? .opacity : .stateChange }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            ZStack {
                symbol
                    .id(mark)
                    .transition(swap)
            }
            .frame(width: symbolSide, height: symbolSide)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // The texts swap on the mark, not on their content,
                // so the run line can tick every second without a
                // swap. The stacks keep the old and new copy on one
                // row while both are on screen.
                ZStack(alignment: .leading) {
                    Text(headline)
                        .font(.headline)
                        .contentTransition(.opacity)
                        .id(mark)
                        .transition(swap)
                }
                if let detail {
                    ZStack(alignment: .leading) {
                        Text(detail)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            // One line while a run moves, so the card
                            // keeps one height as the bytes left change.
                            // The middle goes, so the game and the bytes
                            // left both stay.
                            .lineLimit(monitor.isRunning ? 1 : nil)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .id(mark)
                            .transition(swap)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.sm)
        .animation(reduceMotion ? nil : Motion.standard, value: mark)
        .animation(reduceMotion ? nil : Motion.standard, value: headline)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var symbol: some View {
        switch mark {
        case .running:
            SpinnerRing(
                progress: monitor.fraction ?? 0, size: symbolSide * 0.8, lineWidth: 3,
                tint: AnyShapeStyle(Color.brand), trackOpacity: 0.2)
        case .pausedRun, .paused:
            Image(systemName: "pause.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
        case .ready:
            Image(systemName: "arrow.up.circle.fill")
                .font(.title)
                .foregroundStyle(Color.brand)
        case .healthy:
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.success)
                .symbolEffect(.bounce, options: .nonRepeating, value: status.isHealthy)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.warning)
        }
    }
}
