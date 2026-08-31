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
                Text("No backup has run yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history, id: \.id) { run in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
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
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Backup history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func title(of run: BackupRunRecord) -> String {
        switch run.outcome {
        case .success: return "Backed up"
        case .partial: return "Backed up in part"
        case .failed: return "Did not finish"
        case .cancelled: return "Stopped"
        }
    }

    private static func line(of run: BackupRunRecord, target: String) -> String {
        let games = run.gameCount == 1 ? "1 game" : "\(run.gameCount) games"
        return "\(target), \(games), \(BackupText.bytes(run.uploadedBytes))"
    }

    private func label(of run: BackupRunRecord) -> String {
        model.items.first { $0.id == run.targetId }?.descriptor.displayName ?? "a removed target"
    }
}
