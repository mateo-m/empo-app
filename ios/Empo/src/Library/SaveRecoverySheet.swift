import GameProbe
import SwiftUI

/// Presents the one-time sheet after the pre-literal save heal
/// restored renamed save files (an engine defect in v0.5.0-v0.6.0
/// renamed saves to "*.pre-literal.bak" chains on devices; see
/// `PreLiteralSaveHeal`). Self-contained on purpose: it loads the
/// pending ledger, matches artwork against the loaded library
/// entries, and clears the ledger on any dismissal - the library
/// view only attaches the modifier.
struct SaveRecoveryPresentation: ViewModifier {
    /// Loaded library entries, for artwork matching.
    let games: [GameEntry]

    @State private var records: [SaveRecoveryLedger.Record] = []

    /// Presentation derives from the pending records, and any
    /// dismissal (Done or a swipe) acknowledges them - the sheet
    /// is one-time, like the duplicate-games notice.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { !records.isEmpty },
            set: { presented in
                if !presented {
                    DataDirectory.clearPendingSaveRecoveries()
                    records = []
                }
            }
        )
    }

    /// Artwork per recovered name. The data-directory name is the
    /// INI title for almost every game, and since v0.5 the
    /// container folder name (the entry id) IS the INI title - so
    /// the id match covers the common case and the display-title
    /// match covers custom titles. No match falls back to the
    /// placeholder mark.
    private var artworkPaths: [String: String] {
        var paths: [String: String] = [:]
        for record in records {
            let entry =
                games.first { $0.id == record.name }
                ?? games.first { $0.title == record.name }
            if let path = entry?.artworkPath {
                paths[record.name] = path
            }
        }
        return paths
    }

    func body(content: Content) -> some View {
        content
            .task { records = DataDirectory.pendingSaveRecoveries() }
            .sheet(isPresented: isPresented) {
                SaveRecoverySheet(
                    isPresented: isPresented,
                    records: records,
                    artworkPaths: artworkPaths
                )
            }
    }
}

/// The sheet itself, in the activity-summary shape the system
/// uses for post-update work: a leading symbol and short
/// explanation, one row per recovered game with its artwork and
/// restored files, a per-row "Files" action that jumps straight
/// to the game's data folder, and a footer that says the renamed
/// backup copies still exist - so a user who wanted a different
/// save can restore one by hand.
private struct SaveRecoverySheet: View {
    @Binding var isPresented: Bool
    let records: [SaveRecoveryLedger.Record]
    let artworkPaths: [String: String]

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                header

                VStack(spacing: 0) {
                    let sorted = records.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    ForEach(sorted) { record in
                        if record.id != sorted.first?.id {
                            rowSeparator
                        }
                        SaveRecoveryRow(
                            record: record,
                            artworkPath: artworkPaths[record.name]
                        )
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: Radius.md))

                footer

                Button {
                    isPresented = false
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            .navigationTitle("Saves Recovered")
            .navigationBarTitleDisplayMode(.inline)
        }
        .intrinsicSheetDetent(measuredHeight: measuredHeight)
        // The whole sheet paints one surface - title area, content,
        // and the stretch region a pull-up reveals. A background on
        // the content VStack alone ends at the content bounds and
        // shows a second tone during the pull.
        .presentationBackground(Color(.systemGroupedBackground))
        .tint(.brand)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Image(systemName: "checkmark.arrow.trianglehead.counterclockwise")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.brand)
            Text(
                "A defect in earlier Empo versions renamed save files on this "
                    + "device, so games showed only \u{201C}New Game\u{201D}. "
                    + "Empo restored the most recent save file for each game "
                    + "below."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        Text(
            "The renamed copies stay in the game's data folder as backups "
                + "(\u{201C}.pre-literal.bak\u{201D} files). If a restored "
                + "save is not the one you expect, tap Files on that game "
                + "and rename a backup to the save file's name."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hairline separator indented past the artwork column, the
    /// same rhythm as the image-source rows.
    private var rowSeparator: some View {
        Divider()
            .padding(.leading, Spacing.lg + 44 + Spacing.lg)
    }
}

/// One recovered game: artwork, name, restored files, and the
/// Files-app deep link into `Documents/Data/<name>/`.
private struct SaveRecoveryRow: View {
    let record: SaveRecoveryLedger.Record
    let artworkPath: String?

    var body: some View {
        HStack(spacing: Spacing.lg) {
            GameArtworkView(
                artworkPath: artworkPath,
                placeholderIconSize: 20,
                size: 44,
                cornerRadius: Radius.sm
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Spacing.md)

            Button("Files", action: openInFiles)
                .buttonStyle(SecondaryButtonStyle(size: .sm))
                .fixedSize()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private var subtitle: String {
        record.files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
    }

    private func openInFiles() {
        let path = DataDirectory.sharedRootURL
            .appendingPathComponent(record.name, isDirectory: true).path
        let encoded =
            path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}
