import SwiftUI

/// Per-game confirmation when an import batch collides with more
/// than one installed game. Each conflicting game is individually
/// selectable: selected games update in place (same-path files
/// overwritten, saves and settings kept), deselected ones keep
/// their current files, and non-conflicting games in the batch
/// import regardless. The single-conflict case uses a plain alert
/// instead (`ImportReplaceAlert` in `GameLibraryView`).
///
/// Visual language shared with `ImportRootPickerSheet` via
/// `ImportRootHintBanner` and `ImportRootChoiceArtworkView`.
struct ImportUpdatePickerSheet: View {
    let prompt: ImportReplacePrompt
    let onCancel: () -> Void
    let onConfirm: (Set<String>) -> Void

    @State private var headerHeight: CGFloat = 96
    @State private var selectedIDs: Set<String>

    private let rowHeight: CGFloat = 82
    private let separatorHeight: CGFloat = 1
    private let maxVisibleRows = 5
    private let chromeAllowance: CGFloat = 74

    init(
        prompt: ImportReplacePrompt,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<String>) -> Void
    ) {
        self.prompt = prompt
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        // Updating everything is the expected default; deselecting
        // is the exception.
        _selectedIDs = State(initialValue: Set(prompt.items.map(\.id)))
    }

    private var visibleRowCount: Int {
        min(prompt.items.count, maxVisibleRows)
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(visibleRowCount) * rowHeight
        let separators = CGFloat(max(visibleRowCount - 1, 0)) * separatorHeight
        return rows + separators
    }

    private var sheetContentHeight: CGFloat {
        headerHeight + listHeight
    }

    private var explainer: String {
        var text =
            "Choose which installed games to update with the imported files. "
            + "Deselected games keep their current files. "
            + "Saves and settings are always kept."
        if let unaffected = prompt.unaffectedGamesSentence {
            text += " " + unaffected
        }
        return text
    }

    /// When fresh games ride in the same batch, "Cancel" would read
    /// as aborting them too - it doesn't, so say what it does.
    private var cancelLabel: String {
        prompt.freshCount > 0 ? "Skip Updates" : "Cancel"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ImportRootHintBanner(
                        text: "These games are already in your library",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    Text(explainer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing._2xl)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    headerHeight = newHeight
                }

                if prompt.items.count > maxVisibleRows {
                    ScrollView {
                        itemRows
                    }
                    .frame(height: listHeight)
                } else {
                    itemRows
                }
            }
            .navigationTitle("Update Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelLabel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        onConfirm(selectedIDs)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .intrinsicSheetDetent(
            measuredHeight: sheetContentHeight,
            chromeAllowance: chromeAllowance
        )
        .tint(.brand)
    }

    @ViewBuilder
    private var itemRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(prompt.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                        .padding(.leading, Spacing._2xl + AppSize.listArtwork + Spacing.lg)
                }
                Button {
                    toggleSelection(item.id)
                } label: {
                    ImportUpdateItemRow(item: item, isSelected: selectedIDs.contains(item.id))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        withAnimation(Motion.gentle) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        }
    }
}

private struct ImportUpdateItemRow: View {
    let item: ImportReplacePrompt.Item
    let isSelected: Bool

    private var artwork: ImportRootChoiceArtwork? {
        item.iconPNG.map(ImportRootChoiceArtwork.icon)
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ImportRootChoiceArtworkView(artwork: artwork)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.folderName)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(isSelected ? "Will be updated" : "Keeps current files")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Spacing.md)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, Spacing._2xl)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
    }
}
