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
    @State private var hasUndo = false

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            } footer: {
                Text(
                    "These hold your app settings, your controller buttons, and your on-screen control layouts."
                )
            }
            undoSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { hasUndo = PreferenceRestore.hasUndo() }
        .alert(
            "Use these settings?",
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            presenting: chosen
        ) { row in
            Button("Use them") { run(row) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(PreferenceRestore.confirmation)
        }
    }

    @ViewBuilder
    private var undoSection: some View {
        if hasUndo {
            Section {
                Button(GameProbe.PreferenceRestore.undoLabel) {
                    line =
                        PreferenceRestore.undo()
                        ? String(localized: "Your earlier settings are back.")
                        : String(localized: "Empo couldn't bring back your earlier settings. Try again.")
                    hasUndo = PreferenceRestore.hasUndo()
                }
                .disabled(isRunning)
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
            hasUndo = PreferenceRestore.hasUndo()
            if case .finished = outcome {
                line = String(localized: "Your settings from this backup are back.")
            } else {
                line = RestoreNotices.line(of: outcome)
            }
        }
    }
}
