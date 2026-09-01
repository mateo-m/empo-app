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

    @Environment(\.dismiss) private var dismiss
    @State private var scope: RestoreScope = .savesAndSettings
    @State private var outcome: RestoreOutcome?
    @State private var showsTheMarkerSheet = false

    var body: some View {
        StandardSheet(
            title: "Restore this backup?",
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(
                "\(BackupText.date(row.createdAt)) at \(BackupText.time(row.createdAt)), "
                    + BackupText.bytes(row.bytesToDownload))
            Picker("What to restore", selection: $scope) {
                Text("Saves and settings").tag(RestoreScope.savesAndSettings)
                Text("The whole game").tag(RestoreScope.wholeGame)
            }
            .pickerStyle(.segmented)
            if let line = availability.line {
                SheetFootnote(line)
            }
            if let outcome {
                SheetFootnote(Self.line(of: outcome))
            }
            SheetPrimaryButton("Restore") { press() }
                .disabled(!availability.isAvailable)
        }
        .sheet(isPresented: $showsTheMarkerSheet) {
            VersionMarkerSheetView(gameName: gameName) { action in
                run(scope: action.scope, replacesTheTree: action.replacesTheTree)
            }
        }
    }

    private func press() {
        if VersionMarkerSheet.shows(
            mode: row.mode, scope: scope, markerDiffers: row.versionMarkerDiffers)
        {
            showsTheMarkerSheet = true
            return
        }
        run(scope: scope, replacesTheTree: false)
    }

    private func run(scope: RestoreScope, replacesTheTree: Bool) {
        Task {
            outcome = await restore(row, scope, replacesTheTree)
            if case .finished = outcome { dismiss() }
        }
    }

    private static func line(of outcome: RestoreOutcome) -> String {
        switch outcome {
        case .finished(let result):
            return RestoreNotices.partialPathsLine(count: result.partialPathCount) ?? "Restored."
        case .notEnoughSpace(let shortfall):
            return "This device needs \(BackupText.bytes(shortfall.missingBytes)) more free space."
        case .stopped: return "The restore stopped."
        case .failed(let message): return message
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
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetBodyText(VersionMarkerSheet.body(gameName: gameName))
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

    var body: some View {
        ReadFirst(value: rows) { rows in
            SnapshotListScreen(
                gameName: model.gameName,
                rows: rows,
                gameKey: model.gameKey,
                restore: { row, scope, replacesTheTree in
                    await model.restore(row, scope: scope, replacesTheTree: replacesTheTree)
                })
        }
        .task { rows = await model.snapshots() }
    }
}
