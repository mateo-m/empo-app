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
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                BackupsUnreadableView { Task { await load() } }
            } else {
                list
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $confirmation) { item in
            NamespaceDeleteSheet(confirmation: item.confirmation) {
                try await model.deleteNamespace(item.namespaceId, targetId: targetId)
                await load()
            }
        }
    }

    private func load() async {
        failed = false
        do {
            rows = try await model.namespaces(of: targetId)
        } catch {
            failed = true
        }
    }

    private var list: some View {
        ReadFirst(value: rows) { rows in
            List {
                ForEach(rows, id: \.namespaceId) { row in
                    Section {
                        NavigationLink {
                            NamespaceGamesScreen(model: model, targetId: targetId, row: row)
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(NamespaceListRules.title(of: row))
                                Text(
                                    "\(NamespaceListRules.backups(row.snapshotCount)), "
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
    }

    private func ask(about row: BackupNamespaceRow) {
        guard
            let sheet = NamespaceListRules.confirmation(
                for: row, dateRangeText: Self.rangeText(row))
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
    let delete: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var failed = false

    var body: some View {
        StandardSheet(
            title: confirmation.title,
            barAction: SheetBarAction("Cancel") { dismiss() }
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
            if failed {
                Label(
                    "Empo couldn't delete all of these backups. Try again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SheetDestructiveButton(isDeleting ? "Deleting…" : confirmation.buttonLabel) {
                Task { await run() }
            }
            .disabled(isDeleting)
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func run() async {
        isDeleting = true
        failed = false
        do {
            try await delete()
            dismiss()
        } catch {
            failed = true
        }
        isDeleting = false
    }
}
