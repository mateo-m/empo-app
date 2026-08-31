import GameProbe
import SwiftUI

/// The games one namespace holds, per SPEC 11.3.
///
/// The namespace row is also the browser, so this level and the
/// snapshot level below it are the second manual door of 11.3.
struct NamespaceGamesScreen: View {

    let model: BackupsScreenModel
    let targetId: String
    let row: BackupNamespaceRow

    @State private var sections: [SnapshotGameSection]?

    var body: some View {
        List {
            if let sections {
                if sections.isEmpty {
                    Text(RestoreNotices.emptyTargetLine)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    NavigationLink {
                        SnapshotListScreen(
                            model: model,
                            title: section.game?.folderName ?? RestorePicker.otherSnapshotsHeading,
                            rows: section.rows)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(section.game?.folderName ?? RestorePicker.otherSnapshotsHeading)
                            Text("\(section.rows.count) snapshots")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(NamespaceListRules.title(of: row))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            sections = await model.sections(of: targetId, namespaceId: row.namespaceId)
        }
    }
}

/// One game's snapshots under day headers, per 11.6.
struct SnapshotListScreen: View {

    let model: BackupsScreenModel
    let title: String
    let rows: [SnapshotRow]

    @State private var chosen: SnapshotRow?

    var body: some View {
        List {
            ForEach(RestorePicker.days(rows), id: \.day) { section in
                Section {
                    ForEach(section.rows, id: \.snapshotId) { row in
                        Button {
                            chosen = row
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(BackupText.time(row.createdAt))
                                Text(
                                    "\(row.targetLabel), "
                                        + BackupText.bytes(row.bytesToDownload)
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                if RestoreNotices.showsNewerEmpoLine(row.access) {
                                    Text(RestoreNotices.newerEmpoLine)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(BackupText.date(section.day))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chosen) { row in
            RestoreSnapshotSheet(model: model, row: row)
        }
    }
}

extension SnapshotRow: @retroactive Identifiable {
    public var id: String { snapshotId }
}

/// The one question before a restore starts: how much of the
/// snapshot goes back, per 11.3.
private struct RestoreSnapshotSheet: View {

    let model: BackupsScreenModel
    let row: SnapshotRow

    @Environment(\.dismiss) private var dismiss
    @State private var scope: RestoreScope = .savesAndSettings
    @State private var outcome: RestoreOutcome?

    private var availability: RestoreAvailability {
        RestoreCoordinator.shared.availability(gameKey: row.identity.gameKey)
    }

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
            SheetPrimaryButton("Restore") {
                Task {
                    outcome = await model.restore(row, scope: scope)
                    if case .finished = outcome { dismiss() }
                }
            }
            .disabled(!availability.isAvailable)
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
