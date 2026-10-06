import GameProbe
import SwiftUI

/// The preference snapshots of one namespace, per SPEC 10.9.
///
/// Choosing one is a rollback. On a joined device one confirmation
/// states that the settings change on every joined device.
struct PreferenceSnapshotListScreen: View {

    let rows: [SnapshotRow]
    let restore: (SnapshotRow) async -> RestoreOutcome

    @State private var chosen: SnapshotRow?
    @State private var line: String?
    @State private var isRunning = false

    var body: some View {
        List {
            if let line {
                Section {
                    Text(line).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(rows, id: \.snapshotId) { row in
                    Button {
                        chosen = row
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(
                                "\(BackupText.date(row.createdAt)) at "
                                    + BackupText.time(row.createdAt))
                            Text(BackupText.bytes(row.bytesToDownload))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            } footer: {
                Text("These are your app settings, your controller binds, and your layout profiles.")
            }
            undoSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $chosen) { row in
            Alert(
                title: Text("Use these settings?"),
                message: PreferenceRestore.confirmation.map(Text.init),
                primaryButton: .default(Text("Use them")) { run(row) },
                secondaryButton: .cancel())
        }
    }

    @ViewBuilder
    private var undoSection: some View {
        if PreferenceRestore.hasUndo() {
            Section {
                Button("Undo the last settings change") {
                    line = PreferenceRestore.undo() ? "Your earlier settings are back." : nil
                }
            } footer: {
                Text("Empo keeps one undo for 7 days.")
            }
        }
    }

    private func run(_ row: SnapshotRow) {
        isRunning = true
        Task {
            let outcome = await restore(row)
            isRunning = false
            line = Self.line(of: outcome)
        }
    }

    private static func line(of outcome: RestoreOutcome) -> String {
        switch outcome {
        case .finished: return "These settings are back."
        case .notEnoughSpace(let shortfall):
            return "This device needs \(BackupText.bytes(shortfall.missingBytes)) more free space."
        case .stopped: return "The restore stopped."
        case .failed(let message): return message
        }
    }
}
