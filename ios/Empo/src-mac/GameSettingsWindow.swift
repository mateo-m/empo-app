// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct GameSettingsWindow: View {
    static let id = "game-settings"

    let gameID: String

    var body: some View {
        if let game = GameLibrary.shared.games.first(where: { $0.id == gameID && $0.status == .ready }) {
            GameSettingsForm(game: game)
                .id(game.viewIdentity)
        } else {
            ContentUnavailableView(
                "This game isn't in your library",
                systemImage: "questionmark.folder",
                description: Text("It may have been deleted.")
            )
            .frame(minWidth: 360, minHeight: 240)
        }
    }
}

private struct GameSettingsForm: View {
    let game: GameEntry
    @State private var model: GameSettingsModel
    @State private var showsResetConfirmation = false

    init(game: GameEntry) {
        self.game = game
        _model = State(initialValue: GameSettingsModel(game: game))
    }

    var body: some View {
        NavigationStack {
            Form {
                model.core?.settingsPage(model)

                Section {
                    LabeledContent {
                        Button("Reset to defaults…") { showsResetConfirmation = true }
                            .disabled(!model.hasAnyCustomizations)
                    } label: {
                        Text("Clears every change you made and uses the game's original values.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle(game.title)
        .navigationSubtitle("Settings")
        .alert("Reset all settings?", isPresented: $showsResetConfirmation) {
            Button("Reset", role: .destructive) { model.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every change you made to \"\(game.title)\". You can't undo this.")
        }
        .onChange(of: model.settings) { model.save() }
        .onDisappear { model.save() }
    }
}
