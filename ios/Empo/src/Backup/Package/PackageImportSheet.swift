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
    /// True once a restore finished or stopped. A stopped one keeps
    /// the staged package for the resume question of 11.9.
    private var keepsThePackage = false

    var sourceDevice: String { source?.manifest.sourceDevice ?? "" }
    var exportedAt: Date? { source?.manifest.exportedAt }

    func read(_ picked: URL) {
        do {
            let record = try PackageImport.stage(picked: picked)
            self.record = record
            let source = try PackageImport.open(record)
            self.source = source
            rows = PackageImport.rows(of: source)
        } catch let rejection as PackageRejection {
            self.rejection = rejection.line
            self.record?.delete(localRoot: BackupRoot.url)
            self.record = nil
        } catch {
            rejection = PackageRejection.noManifest.line
            self.record?.delete(localRoot: BackupRoot.url)
            self.record = nil
        }
    }

    func restore(
        _ row: SnapshotRow, scope: RestoreScope, replacesTheTree: Bool
    ) async -> RestoreOutcome {
        guard let source else { return .failed("this package could not be read") }
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

    /// The name one row carries on screen.
    func name(of row: SnapshotRow) -> String {
        if row.identity.containerFolderName.isEmpty { return "your settings" }
        guard let container = GameIdentities.match(row.identity) else {
            return row.identity.containerFolderName
        }
        let metadata = GameMetadata.load(from: container)
        return metadata.customTitle ?? metadata.baseTitle ?? container.folderName
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
            List {
                if let rejection = model.rejection {
                    Section {
                        Text(rejection)
                            .font(.subheadline)
                    }
                } else if let exportedAt = model.exportedAt {
                    Section {
                        Text("\(BackupText.date(exportedAt)) from \(model.sourceDevice)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(model.rows, id: \.snapshotId) { row in
                            Button {
                                chosen = row
                            } label: {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(model.name(of: row))
                                    Text(BackupText.bytes(row.bytesToDownload))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("What this package holds")
                    }
                } else {
                    ProgressView()
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
        .task { model.read(picked) }
        .onDisappear { model.close() }
        .sheet(item: $chosen) { row in
            RestoreSnapshotSheet(
                row: row,
                gameName: model.name(of: row),
                availability: RestoreCoordinator.shared.availability(
                    gameKey: row.identity.gameKey),
                restore: { row, scope, replacesTheTree in
                    await model.restore(row, scope: scope, replacesTheTree: replacesTheTree)
                })
        }
    }
}
