// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LibraryTable: View {
    @Bindable var model: LibraryWindowModel
    @Environment(\.appSettings) private var settings
    @FocusState private var isFocused: Bool

    var body: some View {
        Table(of: GameEntry.self, selection: $model.selection, sortOrder: sortOrder) {
            TableColumn("Title", sortUsing: KeyPathComparator(\GameEntry.title)) { game in
                HStack(spacing: Spacing.md) {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        placeholderIconSize: 14,
                        size: 28,
                        cornerRadius: Radius.xs,
                        importing: game.isImporting,
                        reloadToken: game.artworkRevision
                    )
                    .overlay {
                        if game.status == .invalid {
                            Color.black.opacity(Scrim.light)
                                .clipShape(.pixelRect(cornerRadius: Radius.xs))
                        }
                    }
                    Text(game.title)
                        .lineLimit(1)
                    if game.status == .invalid {
                        InvalidGameBadge()
                    }
                    if game.isImporting {
                        PixelProgressBar(value: game.importProgress)
                            .frame(maxWidth: 80)
                    }
                }
                .opacity(game.isDeleting ? Alpha.disabled : 1)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Last Played", sortUsing: KeyPathComparator(\GameEntry.lastPlayed, order: .reverse)) {
                game in
                TimelineView(.everyMinute) { _ in
                    Text(
                        game.lastPlayed?.formatted(.relative(presentation: .named))
                            ?? String(localized: "Never")
                    )
                    .foregroundStyle(game.lastPlayed == nil ? .secondary : .primary)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn("Play Time", sortUsing: KeyPathComparator(\GameEntry.totalPlayTime, order: .reverse))
            {
                game in
                Text(GameMetadata.formatPlayTime(game.totalPlayTime))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Date Added", sortUsing: KeyPathComparator(\GameEntry.dateAdded, order: .reverse)) {
                game in
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
            if let id = ids.first, let game = model.games.first(where: { $0.id == id }) {
                GameContextMenu(game: game, model: model)
            }
        } primaryAction: { ids in
            if let id = ids.first, let game = model.games.first(where: { $0.id == id }) {
                model.play(game)
            }
        }
        .onDeleteCommand {
            if let game = model.selectedGame { model.requestDelete(game) }
        }
        .focused($isFocused)
        .onAppear { isFocused = true }
    }

    // The table never sorts its rows. A click on a column heading
    // picks the matching library sort, and the library sorts the rows.
    private var sortOrder: Binding<[KeyPathComparator<GameEntry>]> {
        Binding(
            get: {
                switch settings.librarySortOption {
                case .titleAZ: [KeyPathComparator(\.title)]
                case .titleZA: [KeyPathComparator(\.title, order: .reverse)]
                case .recentlyPlayed: [KeyPathComparator(\.lastPlayed, order: .reverse)]
                case .leastRecentlyPlayed: [KeyPathComparator(\.lastPlayed)]
                case .mostPlayed: [KeyPathComparator(\.totalPlayTime, order: .reverse)]
                case .leastPlayed: [KeyPathComparator(\.totalPlayTime)]
                case .recentlyAdded: [KeyPathComparator(\.dateAdded, order: .reverse)]
                case .leastRecentlyAdded: [KeyPathComparator(\.dateAdded)]
                case .largestSize, .smallestSize: []
                }
            },
            set: { order in
                guard let comparator = order.first else { return }
                let forward = comparator.order == .forward
                settings.librarySortOption =
                    switch comparator.keyPath {
                    case \GameEntry.lastPlayed: forward ? .leastRecentlyPlayed : .recentlyPlayed
                    case \GameEntry.totalPlayTime: forward ? .leastPlayed : .mostPlayed
                    case \GameEntry.dateAdded: forward ? .leastRecentlyAdded : .recentlyAdded
                    default: forward ? .titleAZ : .titleZA
                    }
            }
        )
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
        Button("Game Settings…") { openWindow(id: GameSettingsWindow.id, value: game.id) }
            .disabled(!isReady)
        Button("Show in Finder") { model.showInFinder(game) }
            .disabled(game.container == nil)
        Divider()
        Button(game.isImporting ? LocalizedStringKey("Stop Import") : "Delete Game…", role: .destructive) {
            model.requestDelete(game)
        }
        .disabled(!model.canDelete(game))
    }
}
