// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// Key, button and action picker for one binding row (ticket 005 section 4).
struct BindingTargetPicker: View {
    let source: BindingSource
    let current: BindingMap.Target?
    let scope: BindingsCatalog.Scope
    let actions: PlayerActionRegistry
    let onSelect: (BindingMap.Target) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let choices = BindingsCatalog.targetChoices(
            for: source, scope: scope, isAvailable: actions.isAvailable)
        NavigationStack {
            List {
                Section("Actions") {
                    ForEach(choices.actions) { choiceRow($0) }
                }
                if !choices.elements.isEmpty {
                    Section("Controller buttons") {
                        ForEach(choices.elements) { choiceRow($0) }
                    }
                }
                ForEach(choices.keyGroups) { group in
                    Section(group.title) {
                        ForEach(group.choices) { choiceRow($0) }
                    }
                }
            }
            .navigationTitle(BindingsCatalog.label(for: source))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func choiceRow(_ choice: BindingsCatalog.TargetChoice) -> some View {
        Button {
            onSelect(choice.target)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                    ForEach([choice.blurb, choice.note].compactMap { $0 }, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if current == choice.target {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.brand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(choice.enabled ? 1 : 0.4)
        .disabled(!choice.enabled)
    }
}
