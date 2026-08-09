import GameProbe
import SwiftUI

/// Per-game / global button remap screen (ticket 005).
struct ControllerRemapView: View {
    let container: GameContainer?
    let gameTitle: String
    let manifest: BindingMap?
    var controllerInput: ControllerInputManager
    var keyboardInput: KeyboardInputManager

    @Environment(\.dismiss) private var dismiss

    @State private var scope: ControllerRemapCatalog.Scope = .thisGame
    @State private var pickingElement: ControllerRemapCatalog.Element?
    @State private var highlightedElement: String?
    @State private var showResetConfirm = false
    @State private var refreshToken = UUID()
    @State private var listeningForKey = false
    @State private var capturedKey: String?

    private var sections: [ControllerRemapCatalog.Section] {
        _ = refreshToken
        return ControllerRemapCatalog.sections(
            includingOptional: controllerInput.exposedOptionalElements)
    }

    private var keySources: [ControllerRemapCatalog.Element] {
        _ = refreshToken
        return ControllerRemapCatalog.keySources(
            scope: scope, container: container, manifest: manifest)
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

                        if keyboardInput.hasHadKeyboardThisSession {
                            Section {
                                ForEach(keySources) { element in
                                    elementRow(element)
                                        .id(element.id)
                                }
                                Button {
                                    listeningForKey = true
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
            .sheet(isPresented: $listeningForKey) {
                KeyCaptureSheet(keyboardInput: keyboardInput) { code in
                    listeningForKey = false
                    capturedKey = code
                }
            }
            .sheet(item: $pickingElement) { element in
                ControllerBindingPickerSheet(
                    elementLabel: element.label,
                    current: ControllerRemapCatalog.resolvedTarget(
                        element: element.id,
                        scope: scope,
                        container: container,
                        manifest: manifest
                    ),
                    allowsElements: !ControllerElement.allNames.contains(element.id)
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
                keyboardInput.suppressInjection = true
                controllerInput.elementActivityHandler = { element in
                    highlight(element)
                }
                keyboardInput.keyActivityHandler = { code in
                    guard !listeningForKey else { return }
                    highlight(code)
                }
            }
            .onDisappear {
                controllerInput.suppressInjection = false
                keyboardInput.suppressInjection = false
                controllerInput.elementActivityHandler = nil
                keyboardInput.keyActivityHandler = nil
            }
            .onChange(of: listeningForKey) { _, listening in
                // The capture sheet takes the handler while it is up,
                // and this screen never leaves the display, so it has
                // to claim the handler back by hand.
                guard !listening else { return }
                keyboardInput.keyActivityHandler = { code in
                    highlight(code)
                }
            }
            .onChange(of: capturedKey) { _, code in
                guard let code else { return }
                capturedKey = nil
                pickingElement = ControllerRemapCatalog.Element(
                    id: code, label: ControllerRemapCatalog.keyLabel(code))
            }
            .onReceive(NotificationCenter.default.publisher(for: .controllerMapDidChange)) { _ in
                refreshToken = UUID()
            }
        }
        .tint(.brand)
    }

    private func highlight(_ source: String) {
        highlightedElement = source
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if highlightedElement == source {
                highlightedElement = nil
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
            return "Remove all global button overrides. Empo defaults will apply until you remap again."
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
