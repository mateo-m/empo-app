import SwiftUI
import UIKit

struct ImportRootPickerSheet: View {
    let prompt: ImportRootPrompt
    let onCancel: () -> Void
    let onConfirm: ([GameImportValidator.ImportRootChoice]) -> Void
    @State private var headerHeight: CGFloat = 96
    @State private var selectedIDs: Set<String> = []

    private let rowHeight: CGFloat = 82
    private let separatorHeight: CGFloat = 1
    private let maxVisibleRows = 5
    private let chromeAllowance: CGFloat = 74

    private var visibleRowCount: Int {
        min(prompt.choices.count, maxVisibleRows)
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(visibleRowCount) * rowHeight
        let separators = CGFloat(max(visibleRowCount - 1, 0)) * separatorHeight
        return rows + separators
    }

    private var sheetContentHeight: CGFloat {
        headerHeight + listHeight
    }

    private var selectedChoices: [GameImportValidator.ImportRootChoice] {
        prompt.choices.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ImportRootHintBanner(text: "This archive includes more than one game")
                    Text(
                        "Choose one or more games to import, or cancel to go back without importing anything."
                    )
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

                if prompt.choices.count > maxVisibleRows {
                    ScrollView {
                        choiceRows
                    }
                    .frame(height: listHeight)
                } else {
                    choiceRows
                }
            }
            .navigationTitle("Choose Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onConfirm(selectedChoices)
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
    private var choiceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(prompt.choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Divider()
                        .padding(.leading, Spacing._2xl + AppSize.listArtwork + Spacing.lg)
                }
                Button {
                    toggleSelection(choice.id)
                } label: {
                    ImportRootChoiceRow(choice: choice, isSelected: selectedIDs.contains(choice.id))
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

/// Brand-tinted banner atop import sheets. Shared by the root
/// picker and the update picker.
struct ImportRootHintBanner: View {
    let text: String
    var systemImage: String = "square.stack.3d.up.fill"

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)

            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.brand.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

private struct ImportRootChoiceRow: View {
    let choice: GameImportValidator.ImportRootChoice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ImportRootChoiceArtworkView(artwork: choice.artwork)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(choice.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(choice.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
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

/// Square artwork thumbnail for import sheet rows. Shared by the
/// root picker and the update picker.
struct ImportRootChoiceArtworkView: View {
    let artwork: ImportRootChoiceArtwork?

    var body: some View {
        ZStack {
            placeholderBackground
            renderedArtwork
        }
        .frame(width: AppSize.listArtwork, height: AppSize.listArtwork)
        .clipShape(.rect(cornerRadius: Radius.sm))
    }

    @ViewBuilder
    private var renderedArtwork: some View {
        if let data = artwork?.imageData {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderIcon
            }
        } else if let data = artwork?.iconData {
            if let image = UIImage(data: data) {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.75, height: side * 0.75)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                placeholderIcon
            }
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(.empoMark)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(.quaternary)
    }

    private var placeholderBackground: some View {
        ZStack {
            Color(.secondarySystemBackground)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.05), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
