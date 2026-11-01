// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

struct ImportChoiceSheet: View {
    typealias Choice = GameImportValidator.ImportRootChoice

    let onCancel: () -> Void
    let onConfirm: ([Choice], Set<String>) -> Void

    private let freshChoices: [Choice]
    private let updateChoices: [Choice]
    @State private var selectedFreshIDs: Set<String> = []
    @State private var selectedUpdateIDs: Set<String>

    init(
        prompt: ImportRootPrompt, onCancel: @escaping () -> Void,
        onConfirm: @escaping ([Choice], Set<String>) -> Void
    ) {
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        freshChoices = prompt.choices.filter { !prompt.updatingChoiceIDs.contains($0.id) }
        updateChoices = prompt.choices.filter { prompt.updatingChoiceIDs.contains($0.id) }
        _selectedUpdateIDs = State(initialValue: Set(updateChoices.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("This import includes more than one game")
                    .font(.headline)
                Text(
                    updateChoices.isEmpty
                        ? LocalizedStringKey("Choose the games you want to add to your library.")
                        : "Choose the games to import. Games already in your library get updated, and their saves are always kept."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing._2xl)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if !freshChoices.isEmpty {
                        ChoiceGroup(title: "Add games", choices: freshChoices, selection: $selectedFreshIDs)
                    }
                    if !updateChoices.isEmpty {
                        ChoiceGroup(
                            title: "Already in your library", choices: updateChoices,
                            selection: $selectedUpdateIDs)
                    }
                }
                .padding([.horizontal, .bottom], Spacing._2xl)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button(allSelected ? LocalizedStringKey("Deselect All") : "Select All", action: toggleAll)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let selected =
                        freshChoices.filter { selectedFreshIDs.contains($0.id) }
                        + updateChoices.filter { selectedUpdateIDs.contains($0.id) }
                    onConfirm(selected, selectedUpdateIDs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedFreshIDs.isEmpty && selectedUpdateIDs.isEmpty)
            }
            .padding(Spacing.xl)
        }
        .frame(width: 520)
    }

    private var allSelected: Bool {
        selectedFreshIDs.count == freshChoices.count && selectedUpdateIDs.count == updateChoices.count
    }

    private func toggleAll() {
        if allSelected {
            selectedFreshIDs = []
            selectedUpdateIDs = []
        } else {
            selectedFreshIDs = Set(freshChoices.map(\.id))
            selectedUpdateIDs = Set(updateChoices.map(\.id))
        }
    }
}

private struct ChoiceGroup: View {
    let title: LocalizedStringKey
    let choices: [GameImportValidator.ImportRootChoice]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        if choice.id != choices.first?.id { Divider() }
                        ChoiceRow(choice: choice, isOn: isSelected(choice.id))
                    }
                }
            }
        }
    }

    private func isSelected(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}

private struct ChoiceRow: View {
    let choice: GameImportValidator.ImportRootChoice
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.lg) {
                artwork
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: Radius.sm))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(choice.title)
                        .lineLimit(1)
                    if choice.subtitle != choice.title {
                        Text(choice.subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = choice.artwork?.imageData ?? choice.artwork?.iconData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: choice.artwork?.imageData != nil ? .fill : .fit)
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(.empoMark)
                    .resizable()
                    .scaledToFit()
                    .padding(Spacing.md)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
