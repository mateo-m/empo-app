import GameProbe
import SwiftUI

/// The namespace list of SPEC 13.9.
///
/// One row per device that wrote to this target. The row this device
/// writes to carries no delete, because that one goes with the remove
/// flow of 13.10.
struct NamespaceListScreen: View {

    let model: BackupsScreenModel
    let targetId: String

    @State private var rows: [BackupNamespaceRow]?
    @State private var confirmation: NamespaceDeleteConfirmationItem?

    var body: some View {
        List {
            ReadFirst(value: rows) { rows in
                ForEach(rows, id: \.namespaceId) { row in
                    Section {
                        NavigationLink {
                            NamespaceGamesScreen(model: model, targetId: targetId, row: row)
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(NamespaceListRules.title(of: row))
                                Text(
                                    "\(row.snapshotCount) snapshots, "
                                        + BackupText.bytes(row.totalBytes)
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                if let newest = row.newestSnapshotAt {
                                    Text("Newest \(BackupText.date(newest))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if NamespaceListRules.canDelete(row) {
                            Button("Delete", role: .destructive) { ask(about: row) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { rows = (try? await model.namespaces(of: targetId)) ?? [] }
        .sheet(item: $confirmation) { item in
            NamespaceDeleteSheet(confirmation: item.confirmation) {
                Task {
                    await model.deleteNamespace(item.namespaceId, targetId: targetId)
                    rows = (try? await model.namespaces(of: targetId)) ?? []
                }
            }
        }
    }

    private func ask(about row: BackupNamespaceRow) {
        guard
            let sheet = NamespaceListRules.confirmation(
                for: row, gameCount: row.snapshotCount,
                dateRangeText: Self.rangeText(row))
        else { return }
        confirmation = NamespaceDeleteConfirmationItem(
            namespaceId: row.namespaceId, confirmation: sheet)
    }

    private static func rangeText(_ row: BackupNamespaceRow) -> String {
        guard let first = row.oldestSnapshotAt, let last = row.newestSnapshotAt else { return "" }
        return BackupText.range(from: first, to: last)
    }
}

struct NamespaceDeleteConfirmationItem: Identifiable {
    let namespaceId: String
    let confirmation: NamespaceDeleteConfirmation

    var id: String { namespaceId }
}

private struct NamespaceDeleteSheet: View {

    let confirmation: NamespaceDeleteConfirmation
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StandardSheet(
            title: confirmation.title,
            trailingButton: SheetBarAction("Cancel") { dismiss() }
        ) {
            SheetCard {
                ForEach(Array(confirmation.lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 { SheetRowSeparator(leadingColumn: 0) }
                    Text(line)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                }
            }
            SheetFootnote(confirmation.spaceLine)
            Button(confirmation.buttonLabel, role: .destructive) {
                delete()
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle(tint: .red))
        }
    }
}
