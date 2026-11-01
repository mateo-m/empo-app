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

    init(game: GameEntry) {
        self.game = game
        _model = State(initialValue: GameSettingsModel(game: game))
    }

    var body: some View {
        NavigationStack {
            Form {
                if GameLauncher.shared.isPlaying(game) {
                    Section {
                        Label(
                            "Restart this game to apply your changes.",
                            systemImage: "arrow.clockwise.circle.fill"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                model.core?.settingsPage(model)
                ResetSettingsSection(model: model, gameTitle: game.title)
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle(game.title)
        .navigationSubtitle("Settings")
        .tint(.brand)
        .onChange(of: model.settings) { model.save() }
        .onDisappear { model.save() }
    }
}
