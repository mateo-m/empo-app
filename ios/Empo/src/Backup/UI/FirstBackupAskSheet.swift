import GameProbe
import SwiftUI

/// One game the ask of SPEC 3.5 still waits on.
struct BackupModeAsk: Identifiable {
    var container: GameContainer
    var gameName: String
    var ask: BackupThresholdAsk

    var id: String { container.folderName }
}

/// The first-backup ask of SPEC 3.5.
///
/// It shows the same two rows as the mode row of the Backup sheet,
/// because both open `BackupModePickerView`. The save-file editor
/// sits beside them as a standalone sheet, per 3.7.
struct FirstBackupAskSheet: View {

    let model: BackupSheetModel
    let ask: BackupThresholdAsk

    @Environment(\.dismiss) private var dismiss
    @State private var showsTheEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        BackupModePicker.askBody(
                            gameName: model.gameName,
                            sizeText: BackupText.bytes(ask.gameTreeBytes),
                            targetLabel: ask.targetDisplayName,
                            thresholdText: BackupText.bytes(ask.thresholdBytes))
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    BackupModePickerView(
                        fullBytes: model.fullBytes,
                        slimBytes: model.slimBytes,
                        chosen: model.mode
                    ) { mode in
                        Task {
                            await model.setMode(mode)
                            dismiss()
                        }
                    }
                }

                Section {
                    Button(BackupModePicker.saveFileEditorLabel) { showsTheEditor = true }
                }
            }
            .navigationTitle(BackupModePicker.askTitle(gameName: model.gameName))
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.refresh() }
            .sheet(isPresented: $showsTheEditor) {
                NavigationStack {
                    SaveFileEditorView(
                        container: model.container,
                        model: model.editor,
                        canEdit: true
                    ) { edited in
                        Task { await model.setMarks(edited) }
                    }
                }
                .tint(.brand)
            }
        }
        .tint(.brand)
    }
}
