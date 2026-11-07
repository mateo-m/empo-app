// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Observation
import UIKit

@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero

    enum PauseRequest {
        case user
        case background
    }

    /// Who asked for the pause that the core has not yet reported, or
    /// that still holds the game. The core's paused callback has no
    /// request id, so this is the only way to tell whose pause it is.
    /// A background pause stays here until the app returns, so the
    /// return can undo exactly that pause.
    var pauseRequest: PauseRequest?

    private init() {}

    /// The caller must guard `phase == .playing` before the call.
    /// A pause that the user asked for stays the user's pause.
    func requestBackgroundPause() {
        guard pauseRequest == nil else { return }
        pauseRequest = .background
        gamecore_requestPause()
    }

    /// Resume also cancels a background pause that the core has not
    /// reached yet. The Ruby cores report `gamecore_isPaused` only
    /// after they block.
    func resumeFromBackground() {
        guard pauseRequest == .background else { return }
        pauseRequest = nil
        gamecore_requestResume()
    }
}
