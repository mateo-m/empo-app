// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The game session that was open when Empo went to the background.
struct BackgroundSession: Codable, Equatable {
    enum State: String, Codable {
        case loading
        case playing
        case paused
    }

    /// `GameCore.framework`, for example "MkxpCore".
    let core: String
    let runner: GameRunner
    let state: State

    enum EndedProcess: String {
        case empo
        /// The game process, or the game thread in Empo, while Empo still ran.
        case game
    }
}
