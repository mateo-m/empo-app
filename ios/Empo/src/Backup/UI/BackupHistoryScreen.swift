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
                    description: Text("Your first backup shows up here."))
                .listRowBackground(Color.clear)
            }
            ForEach(model.history, id: \.id) { run in
                HStack(alignment: .top, spacing: Spacing.lg) {
                    Image(systemName: Self.symbol(of: run))
                        .font(.title3)
                        .foregroundStyle(Self.color(of: run))
                        .frame(width: IconSize.row + Spacing.md)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.title(of: run))
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
                        if let detail = run.detail {
                            Text(detail.prefix(1).uppercased() + detail.dropFirst())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .navigationTitle("Backup history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func title(of run: BackupRunRecord) -> String {
        switch run.outcome {
        case .success: return "Backed up"
        case .partial: return "Partly backed up"
        case .failed: return "Didn't finish"
        case .cancelled: return "Stopped"
        }
    }

    private static func symbol(of run: BackupRunRecord) -> String {
        switch run.outcome {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private static func color(of run: BackupRunRecord) -> Color {
        switch run.outcome {
        case .success: return .success
        case .partial: return .warning
        case .failed: return .destructive
        case .cancelled: return .secondary
        }
    }

    private static func line(of run: BackupRunRecord, target: String) -> String {
        let games = run.gameCount == 1 ? "1 game" : "\(run.gameCount) games"
        guard run.uploadedBytes > 0 else { return "\(target) · \(games)" }
        return "\(target) · \(games) · \(BackupText.bytes(run.uploadedBytes))"
    }

    private func label(of run: BackupRunRecord) -> String {
        model.items?.first { $0.id == run.targetId }?.descriptor.displayName
            ?? "a removed location"
    }
}
