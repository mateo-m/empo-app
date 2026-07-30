import SwiftUI
import UIKit

/// Root picker for sources that contain more than one game,
/// presented as up to two steps:
///
///   1. **Add Games** - games not in the library yet. Selection
///      starts empty: the user says what they want.
///   2. **Update Games** - games whose title matches an installed
///      game; importing them updates that install in place (files
///      the new version ships are overwritten, saves and settings
///      are kept). Selection starts full: updating is the
///      expected default.
///
/// A source with only one category shows only that step, so each
/// screen carries exactly one verb. The final step's Import
/// launches both sets as one batch. Cancel or swiping the sheet
/// away abandons the whole import.
struct ImportRootPickerSheet: View {
    let prompt: ImportRootPrompt
    let onCancel: () -> Void
    /// Selected choices, plus the subset of choice ids the user
    /// explicitly approved as in-place updates (the "Update Games"
    /// step's selection).
    let onConfirm: ([GameImportValidator.ImportRootChoice], Set<String>) -> Void

    private enum Step {
        case add
        case update
    }

    private let freshChoices: [GameImportValidator.ImportRootChoice]
    private let updateChoices: [GameImportValidator.ImportRootChoice]

    @State private var step: Step
    @State private var headerHeight: CGFloat = 96
    @State private var selectedFreshIDs: Set<String> = []
    @State private var selectedUpdateIDs: Set<String>

    private let rowHeight: CGFloat = 82
    private let separatorHeight: CGFloat = 1
    private let maxVisibleRows = 5
    private let chromeAllowance: CGFloat = 74

    init(
        prompt: ImportRootPrompt,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping ([GameImportValidator.ImportRootChoice], Set<String>) -> Void
    ) {
        self.prompt = prompt
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let updateChoices = prompt.choices.filter { prompt.updatingChoiceIDs.contains($0.id) }
        let freshChoices = prompt.choices.filter { !prompt.updatingChoiceIDs.contains($0.id) }
        self.freshChoices = freshChoices
        self.updateChoices = updateChoices
        _step = State(initialValue: freshChoices.isEmpty ? .update : .add)
        _selectedUpdateIDs = State(initialValue: Set(updateChoices.map(\.id)))
    }

    private var stepChoices: [GameImportValidator.ImportRootChoice] {
        step == .add ? freshChoices : updateChoices
    }

    private var isFinalStep: Bool {
        step == .update || updateChoices.isEmpty
    }

    private var confirmedSelectionCount: Int {
        selectedFreshIDs.count + selectedUpdateIDs.count
    }

    private var navigationTitle: String {
        step == .add ? "Add Games" : "Update Games"
    }

    private var bannerText: String {
        step == .add
            ? "This import includes more than one game"
            : "These games are already in your library"
    }

    private var bannerSystemImage: String {
        step == .add ? "square.stack.3d.up.fill" : "arrow.triangle.2.circlepath"
    }

    private var explainerText: String {
        switch step {
        case .add where updateChoices.isEmpty:
            return "Choose one or more games to add to your library, "
                + "or cancel to go back without importing anything."
        case .add:
            return "Choose which new games to add to your library. "
                + "Next, you'll pick which installed games to update."
        case .update:
            return "Choose which installed games to update with the imported files. "
                + "Deselected games keep their current files. "
                + "Saves and settings are always kept."
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ImportRootHintBanner(text: bannerText, systemImage: bannerSystemImage)
                    Text(explainerText)
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

                if stepChoices.count > maxVisibleRows {
                    ScrollView {
                        choiceRows
                    }
                    .frame(height: listHeight)
                } else {
                    choiceRows
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .update && !freshChoices.isEmpty {
                        Button("Back") {
                            withAnimation(Motion.gentle) { step = .add }
                        }
                    } else {
                        Button("Cancel", action: onCancel)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isFinalStep {
                        Button("Import") {
                            onConfirm(selectedChoices, selectedUpdateIDs)
                        }
                        .disabled(confirmedSelectionCount == 0)
                    } else {
                        Button("Next") {
                            withAnimation(Motion.gentle) { step = .update }
                        }
                    }
                }
            }
        }
        .intrinsicSheetDetent(
            measuredHeight: sheetContentHeight,
            chromeAllowance: chromeAllowance
        )
        .tint(.brand)
    }

    private var visibleRowCount: Int {
        min(stepChoices.count, maxVisibleRows)
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
        freshChoices.filter { selectedFreshIDs.contains($0.id) }
            + updateChoices.filter { selectedUpdateIDs.contains($0.id) }
    }

    @ViewBuilder
    private var choiceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(stepChoices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Divider()
                        .padding(.leading, Spacing._2xl + AppSize.listArtwork + Spacing.lg)
                }
                Button {
                    toggleSelection(choice.id)
                } label: {
                    ImportRootChoiceRow(choice: choice, isSelected: isSelected(choice.id))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ id: String) -> Bool {
        step == .add ? selectedFreshIDs.contains(id) : selectedUpdateIDs.contains(id)
    }

    private func toggleSelection(_ id: String) {
        withAnimation(Motion.gentle) {
            if step == .add {
                if selectedFreshIDs.contains(id) {
                    selectedFreshIDs.remove(id)
                } else {
                    selectedFreshIDs.insert(id)
                }
            } else {
                if selectedUpdateIDs.contains(id) {
                    selectedUpdateIDs.remove(id)
                } else {
                    selectedUpdateIDs.insert(id)
                }
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
