// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

extension PlayerEngine {
    @MainActor static var linked: PlayerEngine {
        PlayerEngine(
            fastForwardMultiplier: { Int(gamecore_getFastForwardMultiplier()) },
            setFastForwardMultiplier: { gamecore_setFastForwardMultiplier(Int32($0)) },
            setCheatsEnabled: { gamecore_setCheatsEnabled($0) },
            tapKey: { EngineSessionCoordinator.shared.injectKeyTap(scancode: $0, holdMilliseconds: $1) })
    }
}

extension PlayerActionRegistry {
    convenience init() {
        self.init(engine: .linked)
    }
}

extension PlayerRuntimeState {
    func bind(container: GameContainer?) {
        bind(
            fastForwardMultiplier: Self.applyRuntimeSettings(of: container),
            cheatsAvailable: GameCores.supportsCheats(in: container))
    }

    /// The settings sheet only opens from the library, so every
    /// runtime edit happens while the game is paused, and this call
    /// picks it up on resume.
    func reconcile(container: GameContainer?) {
        reconcile(fastForwardMultiplier: Self.applyRuntimeSettings(of: container))
    }

    /// Where a `RuntimeFlag` setting reaches the linked engine
    /// mid-session. Returns the game's fast forward multiplier.
    private static func applyRuntimeSettings(of container: GameContainer?) -> Int? {
        GameSettings.assertRuntimeFieldsHaveAppliers()
        guard let container else { return nil }
        let settings = GameSettings.load(from: container.empoStateURL)
        // `eventthread.cpp` reads this atomic on every synthesized
        // mouse event, so the next frame sees the new value.
        gamecore_setTouchMouseEnabled(settings.touchMouseEnabled)
        return settings.speedMultiplier
    }
}
