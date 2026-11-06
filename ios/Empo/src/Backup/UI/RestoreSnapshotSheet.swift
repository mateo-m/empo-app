import GameProbe
import SwiftUI

/// The one question before a restore starts: how much of the
/// snapshot goes back, per SPEC 11.3.
///
/// A full-mode snapshot over a tree whose version marker differs
/// asks the version-marker question of 11.10 first, and that answer
/// replaces this one.
struct RestoreSnapshotSheet: View {

    let row: SnapshotRow
    let gameName: String
    let gameKey: String
    let restore: (SnapshotRow, RestoreScope, Bool) async -> RestoreOutcome

    /// The door of 11.3 answers while the sheet is open. A run that
    /// starts under it closes the button.
    private var availability: RestoreAvailability {
        RestoreCoordinator.shared.availability(gameKey: gameKey)
    }

    /// A snapshot that matches no installed game restores through
    /// the attach of 11.11, and not through a plain Restore.
    private var attaches: Bool {
        guard !row.identity.containerFolderName.isEmpty else { return false }
        return GameIdentities.match(row.identity) == nil
    }

    @Environment(\.dismiss) private var dismiss
    @State private var scope: RestoreScope = .savesAndSettings
    @State private var outcome: RestoreOutcome?
    @State private var isRestoring = false
    @State private var showsTheMarkerSheet = false
    @State private var showsTheAttachSheet = false
    /// The game the attach of 11.11 named, so the question of 11.10
    /// compares against that game's tree and not against none.
    @State private var attachedGame: GameContainer?

    var body: some View {
        Group {
            if case .finished = outcome, let outcome {
                StandardSheet(title: "Restored", emblem: "checkmark.circle") {
                    SheetBodyText(RestoreNotices.line(of: outcome))
                } footer: {
                    SheetPrimaryButton("Done") { dismiss() }
                }
            } else {
                question
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .sheet(isPresented: $showsTheAttachSheet) {
            AttachGameSheet(snapshot: row.identity) { game in
                attachedGame = game
                press()
            }
        }
        .sheet(isPresented: $showsTheMarkerSheet) {
            VersionMarkerSheetView(gameName: gameName) { action in
                run(scope: action.scope, replacesTheTree: action.replacesTheTree)
            }
        }
    }

    private var question: some View {
        StandardSheet(
            title: "Restore this backup?",
            barAction: isRestoring
                ? SheetBarAction("Stop") { Task { await RestoreCoordinator.shared.cancel() } }
                : SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(
                String(
                    localized:
                        "\(BackupText.date(row.createdAt)) at \(BackupText.time(row.createdAt)), \(BackupText.bytes(row.bytesToDownload))"
                ))
            Picker("What to restore", selection: $scope) {
                Text("Saves and settings").tag(RestoreScope.savesAndSettings)
                    .accessibilityLabel("Restore the saves and settings")
                Text("The whole game").tag(RestoreScope.wholeGame)
                    .accessibilityLabel("Restore the whole game")
            }
            .pickerStyle(.segmented)
            .disabled(isRestoring)
            if let line = availability.line, !isRestoring {
                SheetFootnote(line)
            }
            if let outcome {
                Label(RestoreNotices.line(of: outcome), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SheetPrimaryButton(buttonTitle) {
                if attaches {
                    showsTheAttachSheet = true
                } else {
                    press()
                }
            }
            .disabled(!availability.isAvailable || isRestoring)
            if isRestoring {
                ProgressView()
                    .accessibilityLabel("Restoring")
            }
        }
    }

    private var buttonTitle: String {
        if isRestoring { return String(localized: "Restoring…") }
        if attaches { return AttachAction.actionLabel }
        return outcome == nil ? String(localized: "Restore") : String(localized: "Try again")
    }

    private var markerDiffers: Bool {
        guard let attachedGame else { return row.versionMarkerDiffers }
        return GameIdentities.versionMarker(for: attachedGame) != row.versionMarker
    }

    private func press() {
        if VersionMarkerSheet.shows(
            mode: row.mode, scope: scope, markerDiffers: markerDiffers)
        {
            showsTheMarkerSheet = true
            return
        }
        run(scope: scope, replacesTheTree: false)
    }

    private func run(scope: RestoreScope, replacesTheTree: Bool) {
        guard !isRestoring else { return }
        isRestoring = true
        outcome = nil
        Task {
            outcome = await restore(row, scope, replacesTheTree)
            isRestoring = false
        }
    }
}

/// The version-marker sheet of SPEC 11.10. The copy is canonical and
/// lives in `VersionMarkerSheet`, so this view writes none of its
/// own.
struct VersionMarkerSheetView: View {

    let gameName: String
    let choose: (VersionMarkerSheet.Action) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: VersionMarkerSheet.title,
            barAction: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(VersionMarkerSheet.body(gameName: gameName), naming: gameName)
            SheetCard {
                ForEach(Array(VersionMarkerSheet.actions.enumerated()), id: \.element) {
                    index, action in
                    if index > 0 {
                        SheetRowSeparator()
                    }
                    Button {
                        choose(action)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(action.label)
                                .foregroundStyle(.primary)
                            Text(action.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.lg)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// This game's snapshots on every target, per SPEC 11.3. The Backup
/// sheet's "Restore from backup" pushes it.
struct GameRestoreScreen: View {

    let model: BackupSheetModel

    @State private var rows: [SnapshotRow]?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                BackupsUnreadableView { Task { await load() } }
            } else {
                list
            }
        }
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            rows = try await model.snapshots()
        } catch {
            failed = true
        }
    }

    private var list: some View {
        ReadFirst(value: rows) { rows in
            SnapshotListScreen(
                gameName: model.gameName,
                rows: rows,
                gameKey: model.gameKey,
                restore: { row, scope, replacesTheTree in
                    await model.restore(row, scope: scope, replacesTheTree: replacesTheTree)
                })
        }
    }
}
