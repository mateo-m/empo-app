// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// Builds the binding override layers, newest last (SPEC section 9).
@MainActor
enum BindingLayers {
    static func overrideLayers(for container: GameContainer?, manifest: BindingMap?) -> [BindingMap] {
        overrideLayers(
            global: BindingStore.loadGlobal(), manifest: manifest,
            perGame: container.flatMap(BindingStore.loadPerGame))
    }

    static func overrideLayers(
        global: BindingMap?, manifest: BindingMap?, perGame: BindingMap?
    ) -> [BindingMap] {
        [global, manifest, perGame].compactMap { $0 }
    }
}
