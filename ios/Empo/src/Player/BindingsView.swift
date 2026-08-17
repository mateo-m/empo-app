import GameProbe
import SwiftUI

/// Per-game / global binding screen (ticket 005). Controller buttons
/// have fixed rows. Keyboard keys arrive by being pressed.
struct BindingsView: View {
    let container: GameContainer?
    let gameTitle: String
    let manifest: BindingMap?
    var input: SessionInput

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
    @State private var highlighted: String?
    @State private var showResetConfirm = false
    @State private var refreshToken = UUID()

    private var sections: [BindingsCatalog.Section] {
        _ = refreshToken
        return BindingsCatalog.sections(
            includingOptional: input.controller.exposedOptionalElements)
    }

    private var keyRows: [BindingsCatalog.Row] {
        _ = refreshToken
        return BindingsCatalog.keyRows(scope: scope, container: container)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Scope", selection: $scope) {
                    ForEach(BindingsCatalog.Scope.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
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
                                    bindingRow(row).id(row.id)
                                }
                            }
                        }

                        if input.keyboard.hasHadKeyboardThisSession {
                            keyboardSection
                        }
                    }
                    .listStyle(.insetGrouped)
                    .onChange(of: highlighted) { _, row in
                        guard let row else { return }
                        withAnimation(Motion.snappy) {
                            proxy.scrollTo(row, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("Buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(resetTitle) {
                        showResetConfirm = true
                    }
                    .disabled(!BindingsCatalog.hasOverrides(scope: scope, container: container))
                }
            }
            .alert(resetTitle, isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    BindingsCatalog.resetOverrides(scope: scope, container: container)
                    refreshToken = UUID()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetMessage)
            }
            .sheet(item: $step) { step in
                switch step {
                case .capturingKey:
                    KeyCaptureSheet()
                case .choosingTarget(let row):
                    BindingTargetPicker(
                        source: row.source,
                        current: BindingsCatalog.resolvedTarget(
                            source: row.source,
                            scope: scope,
                            container: container,
                            manifest: manifest
                        )
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
                    highlight(element)
                }
                input.keyboard.keyActivityHandler = { code in
                    if case .capturingKey = step {
                        let source = BindingSource.key(code)
                        step = .choosingTarget(
                            BindingsCatalog.Row(
                                source: source, label: BindingsCatalog.label(for: source)))
                    } else {
                        highlight(code)
                    }
                }
            }
            .onDisappear {
                input.suppressInjection = false
                input.controller.elementActivityHandler = nil
                input.keyboard.keyActivityHandler = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .bindingsDidChange)) { _ in
                refreshToken = UUID()
            }
        }
        .tint(.brand)
    }

    @ViewBuilder
    private var keyboardSection: some View {
        Section {
            ForEach(keyRows) { row in
                bindingRow(row).id(row.id)
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
                A controller in keyboard mode sends keys, not buttons. \
                Bind its keys to controller buttons here and every \
                button binding applies to it.
                """
            )
        }
    }

    private func highlight(_ row: String) {
        highlighted = row
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if highlighted == row {
                highlighted = nil
            }
        }
    }

    private var resetTitle: String {
        scope == .thisGame ? "Reset this game's overrides" : "Reset global overrides"
    }

    private var resetMessage: String {
        switch scope {
        case .thisGame:
            return
                "Remove all button overrides for \(gameTitle). Game defaults and global settings will apply again."
        case .allGames:
            return "Remove every global button change. Empo's defaults apply until you set new buttons."
        }
    }

    @ViewBuilder
    private func bindingRow(_ row: BindingsCatalog.Row) -> some View {
        let target = BindingsCatalog.resolvedTarget(
            source: row.source,
            scope: scope,
            container: container,
            manifest: manifest
        )
        let provenance = BindingsCatalog.provenance(
            source: row.source,
            scope: scope,
            container: container,
            manifest: manifest
        )
        let bindingLabel = BindingsCatalog.displayName(for: target)
        let isHighlighted = highlighted == row.id

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
                    if provenance == .gameDefault {
                        Text("game default")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if provenance == .empoDefault {
                        Text("Empo default")
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
        .listRowBackground(
            isHighlighted ? Color.brand.opacity(0.15) : nil
        )
        .contextMenu {
            removeOverrideButton(row, provenance: provenance)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            removeOverrideButton(row, provenance: provenance)
        }
    }

    @ViewBuilder
    private func removeOverrideButton(
        _ row: BindingsCatalog.Row,
        provenance: BindingsCatalog.Provenance?
    ) -> some View {
        if provenance == .userOverride {
            Button("Remove override", role: .destructive) {
                BindingsCatalog.removeOverride(
                    source: row.source,
                    scope: scope,
                    container: container
                )
                refreshToken = UUID()
            }
        }
    }
}
