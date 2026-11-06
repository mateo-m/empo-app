import GameProbe
import SwiftUI

/// Backup history, per SPEC 13.4.
///
/// One row per run, newest first. A failed run keeps the line the
/// provider gave, word for word.
struct BackupHistoryScreen: View {

    let model: BackupsScreenModel

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No backups yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("Your first backup shows up here.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(model.history, id: \.id) { run in
                let state = BackupHistoryState.of(run, passStartedAt: passStartedAt)
                HStack(alignment: .top, spacing: Spacing.lg) {
                    Group {
                        if state == .backingUp {
                            ProgressView()
                        } else {
                            Image(systemName: Self.symbol(of: state))
                                .font(.title3)
                                .foregroundStyle(Self.color(of: state))
                        }
                    }
                    .frame(width: IconSize.row + Spacing.md)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(state.title)
                            Spacer()
                            if let finishedAt = run.finishedAt {
                                Text(BackupText.ago(finishedAt))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(Self.line(of: run, target: label(of: run)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if state != .backingUp, let detail = run.detail {
                            Text(detail.prefix(1).uppercased() + detail.dropFirst())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, Spacing.xxs)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Backup history")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: BackupRunMonitor.shared.isRunning) { _, running in
            if !running { Task { await model.refresh() } }
        }
    }

    private var passStartedAt: Date? {
        let monitor = BackupRunMonitor.shared
        return monitor.isRunning ? monitor.startedAt : nil
    }

    private static func symbol(of state: BackupHistoryState) -> String {
        switch state {
        case .backingUp: return ""
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private static func color(of state: BackupHistoryState) -> Color {
        switch state {
        case .backingUp: return .secondary
        case .success: return .success
        case .partial: return .warning
        case .failed: return .destructive
        case .cancelled: return .secondary
        }
    }

    private static func line(of run: BackupRunRecord, target: String) -> String {
        let games =
            run.gameCount == 1 ? String(localized: "1 game") : String(localized: "\(run.gameCount) games")
        guard run.uploadedBytes > 0 else { return "\(target) · \(games)" }
        return "\(target) · \(games) · \(BackupText.bytes(run.uploadedBytes))"
    }

    private func label(of run: BackupRunRecord) -> String {
        model.items?.first { $0.id == run.targetId }?.descriptor.displayName
            ?? String(localized: "a removed location")
    }
}
