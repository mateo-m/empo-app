import GameProbe
import SwiftUI

/// The import of SPEC 12.6, from the picked file to the restore.
///
/// The package stages first and gets checked before it shows a
/// single row, because a package is the one input in this feature
/// that a stranger produced.
@MainActor
@Observable
final class PackageImportModel {

    private(set) var rows: [SnapshotRow] = []
    private(set) var rejection: String?
    private(set) var record: PackageRecord?
    private(set) var source: PackageSource?
    private(set) var installedGameKeys: [String: String] = [:]
    private let names = BackupGameNames()
    /// True once a restore stopped. The resume question of 11.9 then
    /// owns the staged package, also after a later restore finished.
    private var keepsThePackage = false

    var sourceDevice: String { source?.manifest.sourceDevice ?? "" }
    var exportedAt: Date? { source?.manifest.exportedAt }

    func read(_ picked: URL) async {
        do {
            let record = try await PackageImport.stage(picked: picked)
            // The copy can't stop part way, so a sheet that closed
            // during it deletes the staged package here.
            guard !Task.isCancelled else {
                PackageImport.finish(record)
                return
            }
            self.record = record
            let source = try await PackageImport.open(record)
            self.source = source
            rows = PackageImport.rows(of: source)
            for row in rows {
                installedGameKeys[row.snapshotId] = GameIdentities.match(row.identity).map {
                    BackupKeys.gameKey(containerFolderName: $0.folderName)
                }
            }
        } catch let rejection as PackageRejection {
            self.rejection = rejection.line
            self.record?.delete(localRoot: BackupRoot.layout.root)
            self.record = nil
        } catch {
            rejection = PackageRejection.noManifest.line
            self.record?.delete(localRoot: BackupRoot.layout.root)
            self.record = nil
        }
    }

    func restore(
        _ row: SnapshotRow, scope: RestoreScope, replacesTheTree: Bool
    ) async -> RestoreOutcome {
        guard let source else {
            return .failed(String(localized: "Empo couldn't read this package. Try again."))
        }
        let outcome = await RestoreCoordinator.shared.restore(
            row, into: GameIdentities.match(row.identity), package: source,
            scope: scope, replacesTheTree: replacesTheTree)
        if case .stopped = outcome { keepsThePackage = true }
        return outcome
    }

    /// A successful import deletes the staged package and its staged
    /// files, per 12.6. A stopped one keeps both, and the resume
    /// question of 11.9 owns them from there.
    func close() {
        guard let record, !keepsThePackage else { return }
        PackageImport.finish(record)
        self.record = nil
    }

    func name(of row: SnapshotRow) -> String {
        names.name(of: row.identity)
    }
}

/// The import sheet of SPEC 12.6. It shows one row per included
/// stream, with the package date and the source device in the places
/// a target restore names a target and a namespace.
struct PackageImportSheet: View {

    let picked: URL

    @State private var model = PackageImportModel()
    @State private var chosen: SnapshotRow?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let rejection = model.rejection {
                    List {
                        Section {
                            Text(rejection)
                                .font(.subheadline)
                        }
                    }
                } else {
                    ReadFirst(value: model.exportedAt) { exportedAt in
                        List {
                            Section {
                                Text("\(BackupText.date(exportedAt)) from \(model.sourceDevice)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            let games = model.rows.filter { !$0.identity.containerFolderName.isEmpty }
                            let settings = model.rows.filter { $0.identity.containerFolderName.isEmpty }
                            if !games.isEmpty {
                                Section {
                                    ForEach(games, id: \.snapshotId) { row in
                                        rowButton(row, title: model.name(of: row)) {
                                            BackupGameArtwork(
                                                gameKey: model.installedGameKeys[row.snapshotId])
                                        }
                                    }
                                } header: {
                                    Text("What this package holds")
                                }
                            }
                            if !settings.isEmpty {
                                Section {
                                    ForEach(settings, id: \.snapshotId) { row in
                                        rowButton(row, title: String(localized: "Settings")) { EmptyView() }
                                    }
                                } header: {
                                    if games.isEmpty { Text("What this package holds") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.brand)
        .task { await model.read(picked) }
        .onDisappear { model.close() }
        .sheet(item: $chosen) { row in
            RestoreSnapshotSheet(
                row: row,
                gameName: model.name(of: row),
                gameKey: row.identity.gameKey,
                restore: { row, scope, replacesTheTree in
                    await model.restore(row, scope: scope, replacesTheTree: replacesTheTree)
                })
        }
    }

    private func rowButton(
        _ row: SnapshotRow, title: String, @ViewBuilder artwork: () -> some View
    ) -> some View {
        Button {
            chosen = row
        } label: {
            HStack(spacing: Spacing.md) {
                artwork()
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                    Text(BackupText.bytes(row.bytesToDownload))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
