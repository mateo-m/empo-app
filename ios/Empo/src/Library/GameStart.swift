// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// The steps that each start of a game takes before its core opens, on
/// iOS and on the Mac.
@MainActor
struct GameStart {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    let container: GameContainer
    let core: any GameCore
    let coreBinaryURL: URL
    /// The engine's spelling of the folder for the game's saves
    /// (`DataDirectory.engineSpelling`), or nil when the game keeps
    /// them in its own folder.
    let userDataDirectory: URL?
    let settings: GameSettings

    init(game: GameEntry) throws {
        guard let container = game.container, let core = GameCores.core(forGameAt: container.gameURL) else {
            throw Failure(
                errorDescription: String(
                    localized: "Empo can't find the files of this game. Import it again."))
        }
        guard let coreBinaryURL = core.binaryURL else {
            throw Failure(errorDescription: core.notInThisBuildMessage)
        }
        SaveMigration.migrateLegacySavesIfNeeded(for: container)
        try container.ensureSubdirs()
        self.container = container
        self.core = core
        self.coreBinaryURL = coreBinaryURL
        userDataDirectory = DataDirectory.resolveAndPrepare(for: container, core: core)
            .map(DataDirectory.engineSpelling(of:))
        ManagedMkxpConfig.migrateDisplaySettingsIfNeeded(stateDirectory: container.empoStateURL)
        settings = GameSettings.load(from: container.empoStateURL)
    }
}
