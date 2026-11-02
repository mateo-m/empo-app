// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// Per-game / global binding screen (ticket 005). Controller buttons
/// have fixed rows. Keyboard keys arrive by being pressed.
struct BindingsView: View {
    let container: GameContainer?
    let gameTitle: String?
    let manifest: BindingMap?
    var input: SessionInput
    let actions: PlayerActionRegistry

    @Environment(\.dismiss) private var dismiss

    /// The keyboard flow is two steps and only ever one at a time:
    /// press a key, then choose what it does.
    private enum Step: Identifiable {
        case capturingKey
        case choosingTarget(BindingsCatalog.Row)

        var id: String {
            switch self {
            case .capturingKey: return "capture"
            case .choosingTarget(let row): return row.id
            }
        }
    }

    @State private var scope: BindingsCatalog.Scope = .thisGame
    @State private var step: Step?
    @State private var highlight = PressedRowHighlight()
    @State private var showResetConfirm = false
    @State private var refreshToken = UUID()

    private var sections: [BindingsCatalog.Section] {
        _ = refreshToken
        return BindingsCatalog.sections(
            includingOptional: input.controller.exposedOptionalElements)
    }

    private var saved: BindingsCatalog.SavedBindings {
        _ = refreshToken
        return BindingsCatalog.SavedBindings(scope: scope, container: container, manifest: manifest)
    }

    var body: some View {
        let saved = self.saved
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Applies to", selection: $scope) {
                    ForEach(BindingsCatalog.Scope.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)

                ScrollViewReader { proxy in
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(section.elements) { row in
                                    bindingRow(row, saved: saved).id(row.id)
                                }
                            }
                        }

                        if input.keyboard.hasHadKeyboardThisSession {
                            keyboardSection(saved)
                        }

                        if saved.hasOverrides {
                            Section {
                                Button("Reset to defaults", role: .destructive) {
                                    showResetConfirm = true
                                }
                            } footer: {
                                Text(BindingsCatalog.resetFooter(scope: scope))
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollsToPressedRow(highlight, with: proxy)
                }
            }
            .navigationTitle("Controller buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .resetBindingsAlert(
                isPresented: $showResetConfirm, scope: scope, container: container, gameTitle: gameTitle
            )
            .sheet(item: $step) { step in
                switch step {
                case .capturingKey:
                    KeyCaptureSheet()
                case .choosingTarget(let row):
                    BindingTargetPicker(
                        source: row.source,
                        current: saved.target(for: row.source),
                        scope: scope,
                        actions: actions
                    ) { target in
                        BindingsCatalog.save(
                            source: row.source,
                            target: target,
                            scope: scope,
                            container: container
                        )
                        refreshToken = UUID()
                    }
                }
            }
            .onAppear {
                // The screen reads edges without playing them, and it
                // holds both handlers for its whole life: no child
                // takes them away, so none has to give them back.
                input.suppressInjection = true
                input.controller.elementActivityHandler = { element in
                    highlight.flash(element)
                }
                input.controller.connectionHandler = { refreshToken = UUID() }
                input.keyboard.keyActivityHandler = { code in
                    if case .capturingKey = step {
                        let source = BindingSource.key(code)
                        step = .choosingTarget(
                            BindingsCatalog.Row(
                                source: source, label: BindingsCatalog.label(for: source)))
                    } else {
                        highlight.flash(code)
                    }
                }
            }
            .onDisappear {
                input.suppressInjection = false
                input.controller.elementActivityHandler = nil
                input.controller.connectionHandler = nil
                input.keyboard.keyActivityHandler = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .bindingsDidChange)) { _ in
                refreshToken = UUID()
            }
        }
        .tint(.brand)
    }

    private func keyboardSection(_ saved: BindingsCatalog.SavedBindings) -> some View {
        Section {
            ForEach(saved.keyRows) { row in
                bindingRow(row, saved: saved).id(row.id)
            }
            Button {
                step = .capturingKey
            } label: {
                Label("Add a key", systemImage: "plus")
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text(
                """
                Some controllers send keyboard keys instead of buttons. Add \
                those keys here so they do what your buttons do.
                """
            )
        }
    }

    @ViewBuilder
    private func bindingRow(_ row: BindingsCatalog.Row, saved: BindingsCatalog.SavedBindings) -> some View {
        let target = saved.target(for: row.source)
        let provenance = saved.provenance(for: row.source)
        let bindingLabel = BindingsCatalog.displayName(for: target)

        Button {
            step = .choosingTarget(row)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(row.label)
                        .foregroundStyle(.primary)
                    Text(bindingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let label = provenance?.label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(highlight.background(for: row.id))
        .contextMenu {
            RemoveOverrideButton(row: row, provenance: provenance, scope: scope, container: container)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            RemoveOverrideButton(row: row, provenance: provenance, scope: scope, container: container)
        }
    }
}
