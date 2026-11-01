// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryWindowModel {
    static let importableTypes: [UTType] = [
        .folder, .zip, .sevenZArchive, .rarArchive, .jgpArchive, .exeArchive,
    ]

    let library = GameLibrary.shared
    let importPipeline = ImportPipeline()

    var selection: GameEntry.ID?
    var search = ""
    var showsImporter = false
    var showsInspector = false
    var gameToDelete: GameEntry?
    var launchFailure: LaunchFailure?
    var warnedLaunch: WarnedLaunch?
    var deleteFailure: DeleteFailure?
    var saveRescueFailures: [GameEntry] = []
    private var gameSizes: [String: Int64] = [:]
    @ObservationIgnored private var sizesTask: Task<Void, Never>?

    struct LaunchFailure: Identifiable {
        let id = UUID()
        let message: String
    }

    struct WarnedLaunch {
        let game: GameEntry
        let warning: LaunchWarning
    }

    struct DeleteFailure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        importPipeline.configure(library: library)
    }

    var games: [GameEntry] {
        library.pendingValidationCatalog()
            + library.displayedCatalog(
                search: search, sort: AppSettings.shared.librarySortOption, sizes: gameSizes)
    }

    var selectedGame: GameEntry? {
        guard let selection else { return nil }
        return library.games.first { $0.id == selection }
    }

    var selectedReadyGame: GameEntry? {
        guard let game = selectedGame, game.status == .ready, game.container != nil else { return nil }
        return game
    }

    func importGames(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importPipeline.enqueue(urls)
    }

    func refreshSizesIfNeeded() {
        guard AppSettings.shared.librarySortOption.usesDiskSizes else { return }
        sizesTask?.cancel()
        sizesTask = Task {
            var sizes: [String: Int64] = [:]
            for game in library.games {
                guard !Task.isCancelled else { return }
                guard let container = game.container else { continue }
                sizes[game.id] = await GameMetadata.diskSize(for: container.url)
            }
            guard !Task.isCancelled else { return }
            gameSizes = sizes
        }
    }

    func play(_ game: GameEntry) {
        guard game.status == .ready else { return }
        if !GameLauncher.shared.isPlaying(game), let container = game.container,
            let warning = GameCores.core(forGameAt: container.gameURL)?
                .launchWarning(for: container, gameTitle: game.title)
        {
            warnedLaunch = WarnedLaunch(game: game, warning: warning)
        } else {
            launch(game)
        }
    }

    func launch(_ game: GameEntry) {
        do {
            try GameLauncher.shared.play(game)
        } catch {
            launchFailure = LaunchFailure(message: error.localizedDescription)
        }
    }

    func showInFinder(_ game: GameEntry) {
        guard let container = game.container else { return }
        NSWorkspace.shared.activateFileViewerSelecting([container.url])
    }

    func requestDelete(_ game: GameEntry) {
        guard !game.isDeleting else { return }
        gameToDelete = game
    }

    func delete(_ game: GameEntry, discardingSaves: Bool = false) {
        if selection == game.id { selection = nil }
        let title = game.title
        library.deleteGame(game, skipSaveRescue: discardingSaves) { [weak self] error in
            self?.deleteFailure = DeleteFailure(
                title: String(
                    localized: "Couldn't delete \"\(title)\"",
                    comment: "Alert title. The placeholder is the game's name."),
                message: error)
        } onSaveRescueFailure: { [weak self] failedGame in
            self?.saveRescueFailures.append(failedGame)
        }
    }
}

extension FocusedValues {
    @Entry var libraryWindow: LibraryWindowModel?
}
