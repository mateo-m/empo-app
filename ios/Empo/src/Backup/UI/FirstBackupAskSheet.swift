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
/// sits under them as a standalone sheet, per 3.7.
struct FirstBackupAskSheet: View {

    @State var model: BackupSheetModel
    let ask: BackupThresholdAsk

    @Environment(\.dismiss) private var dismiss
    @State private var showsTheEditor = false

    var body: some View {
        StandardSheet(
            title: BackupModePicker.askTitle,
            barAction: SheetBarAction(BackupModePicker.skipLabel) { dismiss() }
        ) {
            if model.settingsUnread {
                SheetBodyText(
                    String(
                        localized:
                            "Empo couldn't read your backup choices for \(model.gameName), so it's asking again."
                    ),
                    naming: model.gameName)
            }
            SheetBodyText(
                BackupModePicker.askBody(
                    gameName: model.gameName,
                    sizeText: BackupText.bytes(ask.gameTreeBytes),
                    targetLabel: ask.targetDisplayName,
                    thresholdText: BackupText.bytes(ask.thresholdBytes)),
                naming: model.gameName)

            SheetCard {
                BackupModePickerView(
                    fullBytes: model.fullBytes,
                    slimBytes: model.slimBytes,
                    chosen: model.mode,
                    inCard: true
                ) { mode in
                    Task {
                        await model.setMode(mode)
                        dismiss()
                    }
                }
            }

            SheetQuietButton(BackupModePicker.saveFileEditorLabel) { showsTheEditor = true }
                .disabled(model.editor == nil)

            SheetFootnote(BackupModePicker.skipLine(gameName: model.gameName))
        }
        .task { await model.load() }
        .sheet(isPresented: $showsTheEditor) {
            NavigationStack {
                if let editor = model.editor {
                    SaveFileEditorView(
                        container: model.container,
                        model: editor,
                        canEdit: true
                    ) { edited in
                        Task { await model.setMarks(edited) }
                    }
                }
            }
            .tint(.brand)
        }
    }
}
