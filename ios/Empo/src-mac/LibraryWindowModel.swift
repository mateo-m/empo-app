// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

@MainActor
@Observable
final class LibraryWindowModel {
    let library = GameLibrary.shared
    let importPipeline = ImportPipeline()

    var selection: GameEntry.ID?
    var search = ""
    var showsImporter = false
    var showsInspector = false
    var gameToDelete: GameEntry?
    var importToStop: String?
    var invalidReason: String?
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
        return games.first { $0.id == selection }
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
            if let sizes = await GameMetadata.diskSizes(of: library.games) { gameSizes = sizes }
        }
    }

    func play(_ game: GameEntry) {
        switch game.status {
        case .ready:
            if !GameLauncher.shared.isPlaying(game), let warning = library.launchWarning(for: game) {
                warnedLaunch = WarnedLaunch(game: game, warning: warning)
            } else {
                launch(game)
            }
        case .invalid: invalidReason = GameLibrary.whyInvalid(game)
        case .importing, .deleting: break
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

    func canDelete(_ game: GameEntry) -> Bool {
        !game.isDeleting && !GameLauncher.shared.isPlaying(game)
    }

    func requestDelete(_ game: GameEntry) {
        guard canDelete(game) else { return }
        if library.pendingImports[game.id] != nil {
            importToStop = game.id
        } else {
            gameToDelete = game
        }
    }

    func delete(_ game: GameEntry, discardingSaves: Bool = false) {
        if selection == game.id { selection = nil }
        library.delete(game, discardingSaves: discardingSaves) { [weak self] title, message in
            self?.deleteFailure = DeleteFailure(title: title, message: message)
        } onSaveRescueFailure: { [weak self] failedGame in
            self?.saveRescueFailures.append(failedGame)
        }
    }
}

extension FocusedValues {
    @Entry var libraryWindow: LibraryWindowModel?
    @Entry var isSearchingLibrary: Bool?
}
