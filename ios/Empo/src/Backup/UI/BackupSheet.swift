import GameProbe
import SwiftUI

/// The per-game Backup sheet of SPEC 13.15.
///
/// The order is fixed: the header, what gets backed up, the actions,
/// then the cleanup. The destructive part is last.
struct BackupSheet: View {

    let model: BackupSheetModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: LeftoverConfirmation?
    @State private var deletes: LeftoverKind?

    /// Which leftover row the confirmation belongs to.
    private enum LeftoverKind { case trees, files }

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
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(model.gameName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("Backup")
                            .font(.headline)
                    }
                    .sheetTitle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refresh() }
            .sheet(item: $confirmation) { sheet in
                LeftoverDeleteSheet(confirmation: sheet) {
                    Task {
                        if deletes == .trees {
                            await model.deleteTheTrees()
                        } else {
                            await model.deleteTheFiles()
                        }
                    }
                }
            }
            .sheet(item: firstPendingAsk) { ask in
                OversizedWriteAskSheet(path: ask.path, sizeBytes: ask.sizeBytes) { joins in
                    Task { await model.answerTheAsk(path: ask.path, joins: joins) }
                }
            }
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
                    // Ticket 018 fills the byte-weighted bar of 13.2
                    // over the run plan the engine freezes.
                    ProgressView()
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
                SaveFileEditorView(
                    container: model.container,
                    model: model.editor,
                    canEdit: model.locks.canEditSaveFiles
                ) { edited in
                    Task { await model.setMarks(edited) }
                }
            } label: {
                HStack {
                    Text("Save files")
                    Spacer()
                    Text("\(model.editor.entries.count)")
                        .foregroundStyle(.secondary)
                }
            }

            row("In this backup", BackupText.bytes(model.mode == .slim ? model.slimBytes : model.fullBytes))
            row("Stored remotely", BackupText.bytes(model.storedBytes))
        } footer: {
            Text(
                "Empo asks about games over "
                    + "\(BackupText.bytes(BackupThreshold.defaultBytes)). "
                    + "A change to saves and settings only keeps the whole-game backups "
                    + "already made until retention drops them."
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

            // Ticket 019 builds the package writer of 12.5. The row
            // holds its place in the order.
            Button("Export backup") {}
                .disabled(true)
        } footer: {
            if let footer = model.locks.footer {
                Text(footer)
            }
        }
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
                        deletes = .trees
                        confirmation = RestoreLeftovers.replacedTreeConfirmation(
                            gameName: model.gameName,
                            sizeText: BackupText.bytes(model.leftovers.treeBytes))
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
                        deletes = .files
                        confirmation = RestoreLeftovers.displacedCopiesConfirmation(
                            count: model.leftovers.files.count,
                            sizeText: BackupText.bytes(model.leftovers.fileBytes))
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
                Text("Empo backs up no game yet, because no backup target is set up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Set up backups") { BackupsScreen() }
            }
            .padding(.vertical, Spacing.md)
        }
    }

    // MARK: - The oversized write of 3.6

    private var firstPendingAsk: Binding<PendingWriteAsk?> {
        Binding(
            get: {
                model.pendingAsks.first.map {
                    PendingWriteAsk(path: $0, sizeBytes: Self.size(of: $0, in: model.container))
                }
            },
            set: { _ in })
    }

    private static func size(of path: String, in container: GameContainer) -> Int64 {
        let url = container.url.appendingPathComponent(path)
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
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
                    "The whole game comes back on any device. Saves and settings only "
                        + "needs the game files to be there already."
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
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(confirmation.body)
            SheetPrimaryButton(confirmation.buttonLabel) {
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
            trailingButton: SheetBarAction("Not now") {
                answer(false)
                dismiss()
            }
        ) {
            SheetBodyText(
                "The game wrote \(path), which is \(BackupText.bytes(sizeBytes)). "
                    + "A file this large is usually part of the game and not a save.")
            SheetPrimaryButton("Back it up") {
                answer(true)
                dismiss()
            }
        }
    }
}
