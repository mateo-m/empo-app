import GameProbe
import SwiftUI

/// The card at the top of the Backups screen, per SPEC 13.4.
///
/// One symbol, one headline, one line under it. While a run moves,
/// the ring fills, the run line takes the second row, and a bar
/// shows the share done. The ring turns into the checkmark when the
/// run ends.
struct BackupStatusCard: View {

    let status: BackupsScreenStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            ZStack {
                symbol
                    .id(mark)
                    .transition(reduceMotion ? .opacity : .fadeBlur)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(headline)
                    .font(.headline)
                    .contentTransition(.opacity)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                if monitor.isRunning {
                    progress
                        .padding(.top, Spacing.xs)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.sm)
        .animation(reduceMotion ? nil : Motion.standard, value: mark)
        .animation(reduceMotion ? nil : Motion.standard, value: headline)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var progress: some View {
        if let fraction = monitor.fraction {
            ProgressView(value: fraction)
                .tint(.brand)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.brand)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch mark {
        case .running:
            SpinnerRing(
                progress: monitor.fraction ?? 0, size: 26, lineWidth: 3,
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
