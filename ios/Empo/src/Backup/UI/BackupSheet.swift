import GameProbe
import SwiftUI

/// The per-game Backup sheet of SPEC 13.15.
///
/// The order is fixed: the header, what gets backed up, the actions,
/// then the cleanup. The destructive part is last.
struct BackupSheet: View {

    @Bindable var model: BackupSheetModel

    @Environment(\.dismiss) private var dismiss
    @State private var sheets = SheetQueue<Sheet>()

    /// Which leftover row the confirmation belongs to.
    private enum LeftoverKind { case trees, files }

    private enum Sheet: Identifiable {
        case leftovers(LeftoverConfirmation, LeftoverKind)
        case export
        case ask(PendingWriteAsk)

        var id: String {
            switch self {
            case .leftovers(let confirmation, _): "leftovers-" + confirmation.id
            case .export: "export"
            case .ask(let ask): "ask-" + ask.id
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.hasATarget {
                    header
                    backupSetSection
                    actionsSection
                    leftoversSection
                } else {
                    noTargetSection
                    Section { exportButton }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar {
                VStack(spacing: 1) {
                    Text(model.gameName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Backup")
                        .font(.headline)
                }
            } done: {
                dismiss()
            }
            .task { await model.load() }
            .onChange(of: model.pendingAsk?.id, initial: true) {
                if let ask = model.pendingAsk { sheets.show(.ask(ask)) }
            }
            .sheet(
                item: $sheets.presented, onDismiss: { sheets.closed() },
                content: { sheet in
                    switch sheet {
                    case .leftovers(let confirmation, let kind):
                        LeftoverDeleteSheet(confirmation: confirmation) {
                            Task {
                                switch kind {
                                case .trees: await model.deleteTheTrees()
                                case .files: await model.deleteTheFiles()
                                }
                            }
                        }
                    case .export:
                        PackageExportSheet(source: .game(model.container))
                    case .ask(let ask):
                        OversizedWriteAskSheet(path: ask.path, sizeBytes: ask.sizeBytes) { joins in
                            Task { await model.answerTheAsk(path: ask.path, joins: joins) }
                        }
                        // A swipe would close the ask with no answer, and the
                        // write would wait for one with no sheet to give it.
                        .interactiveDismissDisabled()
                    }
                })
        }
        .tint(.brand)
    }

    // MARK: - The header, per 13.15

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(model.line)
                    .font(.headline)
                if let cause = model.status.causeLine {
                    Text(cause)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.locks.backUpNowIsPause {
                    // The bar counts the run plan the engine froze at
                    // staging end, per 13.2.
                    ProgressView(
                        value: BackupRunMonitor.shared.plan.fraction(ofStream: model.gameKey) ?? 0
                    )
                    .progressViewStyle(.linear)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    // MARK: - "What gets backed up", per 13.15

    private var backupSetSection: some View {
        Section {
            NavigationLink {
                ModePickerScreen(model: model)
            } label: {
                HStack {
                    Text("What gets backed up")
                    Spacer()
                    Text(BackupModePicker.label(of: model.mode))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.locks.canChangeMode)

            NavigationLink {
                if let editor = model.editor {
                    SaveFileEditorView(
                        container: model.container,
                        model: editor,
                        canEdit: model.locks.canEditSaveFiles
                    ) { edited in
                        Task { await model.setMarks(edited) }
                    }
                }
            } label: {
                HStack {
                    Text("Save files")
                    Spacer()
                    if let editor = model.editor {
                        Text("\(editor.entries.count)")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .disabled(model.editor == nil)

            row(
                String(localized: "In this backup"),
                BackupText.bytes(model.mode == .slim ? model.slimBytes : model.fullBytes))
            row(String(localized: "Stored remotely"), BackupText.bytes(model.storedBytes))
        } footer: {
            Text(
                String(
                    localized:
                        "If you switch to saves and settings only, Empo keeps the whole-game backups it already made until they're old enough to delete."
                )
            )
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The actions, per 13.15

    private var actionsSection: some View {
        Section {
            if model.locks.backUpNowIsPause {
                Button("Pause") { model.pause() }
            } else {
                Button("Back up now") { model.backUpNow() }
                    .disabled(!model.locks.canBackUpNow)
            }

            NavigationLink {
                GameRestoreScreen(model: model)
            } label: {
                Text("Restore from backup")
            }
            .disabled(!model.locks.canRestore)

            exportButton
        } footer: {
            if let footer = model.locks.footer {
                Text(footer)
            }
        }
    }

    private var exportButton: some View {
        Button("Export backup") { sheets.show(.export) }
            .disabled(!model.locks.canExport)
    }

    // MARK: - "Left over from a restore", per 11.12

    @ViewBuilder private var leftoversSection: some View {
        if !model.leftovers.isEmpty {
            Section {
                if !model.leftovers.trees.isEmpty {
                    Button(
                        RestoreLeftovers.replacedTreeRow(
                            sizeText: BackupText.bytes(model.leftovers.treeBytes)),
                        role: .destructive
                    ) {
                        let confirmation = RestoreLeftovers.replacedTreeConfirmation(
                            gameName: model.gameName,
                            sizeText: BackupText.bytes(model.leftovers.treeBytes))
                        sheets.show(.leftovers(confirmation, .trees))
                    }
                    .disabled(!model.locks.canDeleteLeftovers)
                }
                if !model.leftovers.files.isEmpty {
                    Button(
                        RestoreLeftovers.displacedCopiesRow(
                            count: model.leftovers.files.count,
                            sizeText: BackupText.bytes(model.leftovers.fileBytes)),
                        role: .destructive
                    ) {
                        let confirmation = RestoreLeftovers.displacedCopiesConfirmation(
                            count: model.leftovers.files.count,
                            sizeText: BackupText.bytes(model.leftovers.fileBytes))
                        sheets.show(.leftovers(confirmation, .files))
                    }
                    .disabled(!model.locks.canDeleteLeftovers)
                }
            } header: {
                Text(RestoreLeftovers.heading)
            } footer: {
                if let warning = model.leftovers.warning {
                    Text(warning)
                }
            }
        }
    }

    // MARK: - No target, per 13.15

    private var noTargetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Your games aren't backed up yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Set up backups") { BackupsScreen() }
            }
            .padding(.vertical, Spacing.md)
        }
    }
}

/// One oversized write waiting for an answer, per SPEC 3.6.
struct PendingWriteAsk: Identifiable {
    let path: String
    let sizeBytes: Int64

    var id: String { path }
}

extension LeftoverConfirmation: @retroactive Identifiable {
    public var id: String { title }
}

/// The mode picker of 3.5, pushed from the mode row.
private struct ModePickerScreen: View {

    let model: BackupSheetModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
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
            } footer: {
                Text(
                    String(
                        localized:
                            "The whole game comes back on any device. Saves and settings only needs the game files to be there already."
                    )
                )
            }
        }
        .navigationTitle(BackupModePicker.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One leftover delete of 13.15, which names what goes.
private struct LeftoverDeleteSheet: View {

    let confirmation: LeftoverConfirmation
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: confirmation.title,
            barAction: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(confirmation.body)
            SheetDestructiveButton(confirmation.buttonLabel) {
                delete()
                dismiss()
            }
        }
    }
}

/// The oversized watched write of SPEC 3.6, asked once per file.
private struct OversizedWriteAskSheet: View {

    let path: String
    let sizeBytes: Int64
    let answer: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: "Back up this file too?",
            barAction: SheetBarAction("Not now") {
                answer(false)
                dismiss()
            }
        ) {
            SheetBodyText(
                String(
                    localized:
                        "The game wrote \(path), which is \(BackupText.bytes(sizeBytes)). A file this large is usually part of the game and not a save."
                ))
            SheetPrimaryButton("Back it up") {
                answer(true)
                dismiss()
            }
        }
    }
}
