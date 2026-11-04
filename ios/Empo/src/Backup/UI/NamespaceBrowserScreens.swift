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

    @State private var contents: NamespaceContents?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                BackupsUnreadableView { Task { await load() } }
            } else {
                list
            }
        }
        .navigationTitle(NamespaceListRules.title(of: row))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            contents = try await model.contents(of: targetId, namespaceId: row.namespaceId)
        } catch {
            failed = true
        }
    }

    private var list: some View {
        List {
            ReadFirst(value: contents?.games) { sections in
                if sections.isEmpty {
                    Text(RestoreNotices.emptyTargetLine)
                        .foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    NavigationLink {
                        SnapshotListScreen(
                            gameName: section.name,
                            rows: section.rows,
                            gameKey: section.id,
                            restore: { row, scope, replacesTheTree in
                                await model.restore(
                                    row, scope: scope, replacesTheTree: replacesTheTree)
                            })
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(section.name)
                            Text(NamespaceListRules.backups(section.rows.count))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                preferences
            }
        }
    }
}

/// What a backup list shows when Empo could not read the location.
/// An empty list would say there are no backups, which is not true.
struct BackupsUnreadableView: View {

    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't read the backups", systemImage: "exclamationmark.icloud")
        } description: {
            Text(RestoreNotices.scanFailedLine)
        } actions: {
            Button("Try again", action: retry)
        }
    }
}

extension NamespaceGamesScreen {

    /// The rollback points of 10.9. The stream is one export file,
    /// so the list needs no scope question.
    @ViewBuilder
    fileprivate var preferences: some View {
        if let rows = contents?.preferences, !rows.isEmpty {
            Section {
                NavigationLink {
                    PreferenceSnapshotListScreen(rows: rows) { row in
                        await model.restore(row, scope: .preferences)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Settings")
                        Text(NamespaceListRules.backups(rows.count))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One game's snapshots under day headers, per 11.6.
struct SnapshotListScreen: View {

    let gameName: String
    let rows: [SnapshotRow]
    let gameKey: String
    let restore: (SnapshotRow, RestoreScope, Bool) async -> RestoreOutcome

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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(BackupText.date(section.day))
                }
            }
        }
        .navigationTitle(gameName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chosen) { row in
            RestoreSnapshotSheet(
                row: row, gameName: gameName, gameKey: gameKey, restore: restore)
        }
    }
}

extension SnapshotRow: @retroactive Identifiable {
    public var id: String { snapshotId }
}
