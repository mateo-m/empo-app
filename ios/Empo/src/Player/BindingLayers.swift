// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// Builds the binding override layers, newest last (SPEC section 9).
@MainActor
enum BindingLayers {
    static func overrideLayers(for container: GameContainer?, manifest: BindingMap?) -> [BindingMap] {
        [BindingStore.loadGlobal(), manifest, container.flatMap(BindingStore.loadPerGame)].compactMap { $0 }
    }
}
