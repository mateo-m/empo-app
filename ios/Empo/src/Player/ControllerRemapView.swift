import GameProbe
import SwiftUI

/// Per-game / global controller remap screen (ticket 005).
struct ControllerRemapView: View {
    let container: GameContainer?
    let gameTitle: String
    let manifest: ControllerMap?
    var controllerInput: ControllerInputManager

    @Environment(\.dismiss) private var dismiss

    @State private var scope: ControllerRemapCatalog.Scope = .thisGame
    @State private var pickingElement: ControllerRemapCatalog.Element?
    @State private var highlightedElement: String?
    @State private var showResetConfirm = false
    @State private var refreshToken = UUID()

    private var sections: [ControllerRemapCatalog.Section] {
        _ = refreshToken
        return ControllerRemapCatalog.sections(
            includingOptional: controllerInput.exposedOptionalElements)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Scope", selection: $scope) {
                    ForEach(ControllerRemapCatalog.Scope.allCases, id: \.self) { option in
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
                                ForEach(section.elements) { element in
                                    elementRow(element)
                                        .id(element.id)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .onChange(of: highlightedElement) { _, element in
                        guard let element else { return }
                        withAnimation(Motion.snappy) {
                            proxy.scrollTo(element, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(resetTitle) {
                        showResetConfirm = true
                    }
                    .disabled(!ControllerRemapCatalog.hasOverrides(scope: scope, container: container))
                }
            }
            .alert(resetTitle, isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    ControllerRemapCatalog.resetOverrides(scope: scope, container: container)
                    refreshToken = UUID()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetMessage)
            }
            .sheet(item: $pickingElement) { element in
                ControllerBindingPickerSheet(
                    elementLabel: element.label,
                    current: ControllerRemapCatalog.resolvedTarget(
                        element: element.id,
                        scope: scope,
                        container: container,
                        manifest: manifest
                    )
                ) { target in
                    ControllerRemapCatalog.save(
                        element: element.id,
                        target: target,
                        scope: scope,
                        container: container
                    )
                    refreshToken = UUID()
                }
            }
            .onAppear {
                controllerInput.suppressInjection = true
                controllerInput.elementActivityHandler = { element in
                    highlightedElement = element
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        if highlightedElement == element {
                            highlightedElement = nil
                        }
                    }
                }
            }
            .onDisappear {
                controllerInput.suppressInjection = false
                controllerInput.elementActivityHandler = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .controllerMapDidChange)) { _ in
                refreshToken = UUID()
            }
        }
        .tint(.brand)
    }

    private var resetTitle: String {
        scope == .thisGame ? "Reset this game's overrides" : "Reset global overrides"
    }

    private var resetMessage: String {
        switch scope {
        case .thisGame:
            return
                "Remove all controller overrides for \(gameTitle). Game defaults and global settings will apply again."
        case .allGames:
            return "Remove all global controller overrides. Empo defaults will apply until you remap again."
        }
    }

    @ViewBuilder
    private func elementRow(_ element: ControllerRemapCatalog.Element) -> some View {
        let target = ControllerRemapCatalog.resolvedTarget(
            element: element.id,
            scope: scope,
            container: container,
            manifest: manifest
        )
        let provenance = ControllerRemapCatalog.provenance(
            element: element.id,
            scope: scope,
            container: container,
            manifest: manifest
        )
        let bindingLabel = ControllerRemapCatalog.displayName(for: target)
        let isHighlighted = highlightedElement == element.id

        Button {
            pickingElement = element
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(element.label)
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
            if provenance == .userOverride {
                Button("Remove override", role: .destructive) {
                    ControllerRemapCatalog.removeOverride(
                        element: element.id,
                        scope: scope,
                        container: container
                    )
                    refreshToken = UUID()
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if provenance == .userOverride {
                Button("Remove override", role: .destructive) {
                    ControllerRemapCatalog.removeOverride(
                        element: element.id,
                        scope: scope,
                        container: container
                    )
                    refreshToken = UUID()
                }
            }
        }
    }
}
