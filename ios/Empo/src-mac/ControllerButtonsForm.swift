// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct ControllerButtonsForm: View {
    /// Nil for the buttons of all games.
    let game: GameEntry?
    var fastForwardMultiplier: Int?

    @State private var registry = PlayerActionRegistry(engine: .none)
    @State private var manifest: BindingMap?
    @State private var refreshToken = UUID()
    @State private var showResetConfirm = false
    @State private var saveRefusal: UserControlsFile.SaveRefusal?

    private var scope: BindingsCatalog.Scope { container.map(BindingsCatalog.Scope.thisGame) ?? .allGames }
    private var container: GameContainer? { game?.container }
    private var listener: ControllerPressListener { .shared }

    private var saved: BindingsCatalog.SavedBindings {
        _ = refreshToken
        return BindingsCatalog.SavedBindings(scope: scope, manifest: manifest)
    }

    var body: some View {
        let saved = self.saved
        ScrollViewReader { proxy in
            Form {
                if game == nil {
                    ControllerSetupSection()
                }

                Section {
                    Label("Press a button on your controller to find it here.", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }

                ForEach(BindingsCatalog.sections(includingOptional: listener.optionalElements)) { section in
                    Section(section.title) {
                        ForEach(section.elements) { row in
                            buttonRow(row, saved: saved).id(row.id)
                        }
                    }
                }

                if saved.hasOverrides {
                    Section {
                        LabeledContent {
                            Button("Reset", role: .destructive) { showResetConfirm = true }
                        } label: {
                            Text("Reset to defaults")
                            Text(BindingsCatalog.resetFooter(scope: scope))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollsToPressedRow(listener.highlight, with: proxy)
        }
        .resetBindingsAlert(
            isPresented: $showResetConfirm, scope: scope, gameTitle: game?.title, refusal: $saveRefusal
        )
        .bindingsSaveRefusalAlert($saveRefusal)
        .onAppear {
            manifest = container.flatMap {
                ControlsManifestLoader.load(gameRoot: $0.gameURL)?.result.manifest?.bindings
            }
            registry.runtime.bind(
                fastForwardMultiplier: fastForwardMultiplier,
                cheatsAvailable: GameCores.supportsCheats(in: container))
            listener.begin()
        }
        .onDisappear { listener.end() }
        .onReceive(NotificationCenter.default.publisher(for: .bindingsDidChange)) { _ in
            refreshToken = UUID()
        }
    }

    private func buttonRow(_ row: BindingsCatalog.Row, saved: BindingsCatalog.SavedBindings) -> some View {
        let target = saved.target(for: row.source)
        let provenance = saved.provenance(for: row.source)
        // The Mac settings for all games open with no game, so no game
        // can lack an action there.
        let choices = BindingsCatalog.targetChoices(
            for: row.source, scope: scope,
            isAvailable: { game == nil || registry.isAvailable($0) })

        return LabeledContent {
            Menu(BindingsCatalog.displayName(for: target)) {
                Section("Actions") {
                    ForEach(choices.actions) { choice($0, row: row, current: target) }
                }
                Section("Keys") {
                    ForEach(choices.keyGroups) { group in
                        Menu(group.title) {
                            ForEach(group.choices) { choice($0, row: row, current: target) }
                        }
                    }
                }
            }
            .fixedSize()
        } label: {
            Text(row.label)
            if let label = provenance?.label { Text(label) }
        }
        // A grouped Form on macOS ignores listRowBackground.
        .background(
            listener.highlight.background(for: row.id).padding(.horizontal, -10).padding(.vertical, -7)
        )
        .contentShape(.rect)
        .contextMenu {
            RemoveOverrideButton(row: row, provenance: provenance, scope: scope, refusal: $saveRefusal)
        }
    }

    /// The blurb of an action tells what it does on iOS, so an action
    /// shows only its note.
    private func choice(
        _ choice: BindingsCatalog.TargetChoice,
        row: BindingsCatalog.Row,
        current: BindingMap.Target?
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { current == choice.target },
                set: { _ in
                    do throws(UserControlsFile.SaveRefusal) {
                        try BindingsCatalog.save(source: row.source, target: choice.target, scope: scope)
                    } catch {
                        saveRefusal = error
                    }
                })
        ) {
            Text(choice.title)
            let line = if case .key = choice.target { choice.blurb } else { choice.note }
            if let line { Text(line) }
        }
        .disabled(!choice.enabled)
    }
}

/// Settings > Controller and the buttons of a game can be open at the
/// same time. A controller keeps one handler for each button, so the
/// two lists share one listener.
@MainActor @Observable
final class ControllerPressListener {
    static let shared = ControllerPressListener()

    let highlight = PressedRowHighlight()
    /// The paddles and other extra buttons that a connected controller has.
    private(set) var optionalElements: Set<String> = []

    @ObservationIgnored private let controllers = ControllerInputManager(keys: HeldKeys(send: { _, _ in }))
    @ObservationIgnored private var lists = 0
    @ObservationIgnored private var setupSheets = 0
    private var listening: Bool { lists > 0 && setupSheets == 0 }

    private init() {
        controllers.suppressInjection = true
        controllers.elementActivityHandler = { [highlight] in highlight.flash($0) }
        controllers.connectionHandler = { [weak self] in
            guard let self else { return }
            optionalElements = controllers.exposedOptionalElements
        }
    }

    func begin() { update { lists += 1 } }
    func end() { update { lists -= 1 } }

    /// The controller setup sheet reads the presses itself, so no list
    /// lights up while a sheet is open.
    func setupSheetAppeared() { update { setupSheets += 1 } }
    func setupSheetDisappeared() { update { setupSheets -= 1 } }

    private func update(_ change: () -> Void) {
        let wasListening = listening
        change()
        guard listening != wasListening else { return }
        if listening {
            controllers.start()
            optionalElements = controllers.exposedOptionalElements
        } else {
            controllers.stop()
        }
    }
}
