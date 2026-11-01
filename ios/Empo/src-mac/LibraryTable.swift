// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LibraryTable: View {
    @Bindable var model: LibraryWindowModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Table(of: GameEntry.self, selection: $model.selection) {
            TableColumn("Title") { game in
                HStack(spacing: Spacing.md) {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        placeholderIconSize: 14,
                        size: 28,
                        cornerRadius: Radius.xs,
                        importing: game.isImporting,
                        reloadToken: game.artworkRevision
                    )
                    Text(game.title)
                        .lineLimit(1)
                    if game.isImporting {
                        ProgressView(value: game.importProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 80)
                    }
                }
                .opacity(game.isDeleting ? 0.4 : 1)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Last played") { game in
                Text(
                    game.lastPlayed?.formatted(date: .abbreviated, time: .omitted)
                        ?? String(localized: "Never")
                )
                .foregroundStyle(game.lastPlayed == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Play time") { game in
                Text(GameMetadata.formatPlayTime(game.totalPlayTime))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Date added") { game in
                Text(
                    game.dateAdded?.formatted(date: .abbreviated, time: .omitted)
                        ?? String(localized: "Unknown"))
            }
            .width(min: 100, ideal: 130)
        } rows: {
            // An import replaces its placeholder entry with a new one under the same `id`.
            ForEach(model.games, id: \.viewIdentity) { game in
                TableRow(game)
            }
        }
        .contextMenu(forSelectionType: GameEntry.ID.self) { ids in
            if let id = ids.first, let game = model.library.games.first(where: { $0.id == id }) {
                GameContextMenu(game: game, model: model)
            }
        } primaryAction: { ids in
            if let id = ids.first, let game = model.library.games.first(where: { $0.id == id }) {
                model.play(game)
            }
        }
        .onDeleteCommand {
            if let game = model.selectedGame { model.requestDelete(game) }
        }
        .focused($isFocused)
        .onAppear { isFocused = true }
    }
}

struct GameContextMenu: View {
    let game: GameEntry
    let model: LibraryWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let isReady = game.status == .ready && game.container != nil
        Button("Play") { model.play(game) }
            .disabled(!isReady)
        Divider()
        Button("Get Info") {
            model.selection = game.id
            model.showsInspector = true
        }
        .disabled(!isReady)
        Button("Game Settings…") { openWindow(id: GameSettingsWindow.id, value: game.id) }
            .disabled(!isReady)
        Button("Show in Finder") { model.showInFinder(game) }
            .disabled(!isReady)
        Divider()
        Button(game.isImporting ? LocalizedStringKey("Stop Import") : "Delete Game…", role: .destructive) {
            model.requestDelete(game)
        }
        .disabled(game.isDeleting)
    }
}
