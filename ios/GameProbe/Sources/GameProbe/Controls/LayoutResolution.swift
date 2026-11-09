// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum LayoutResolution {
    public static func resolve(
        pin: LayoutPin,
        gameLayoutOccupied: Bool,
        store: LayoutProfileStore,
        defaultProfileName: String?
    ) -> LayoutChainResolver.Outcome {
        func level(_ name: String) -> (name: String, valid: Bool) {
            (name, store.validTouch(name) != nil)
        }
        var pinnedProfile: (name: String, valid: Bool)?
        if case .profile(let name) = pin {
            pinnedProfile = level(name)
        }
        return LayoutChainResolver.resolve(
            pin: pin,
            levels: LayoutChainResolver.Levels(
                pinnedProfile: pinnedProfile,
                gameLayoutOccupied: gameLayoutOccupied,
                defaultProfile: defaultProfileName.map(level)))
    }

    public static func resolve(
        pin: LayoutPin,
        gameRoot: URL,
        store: LayoutProfileStore,
        defaultProfileName: String?,
        metrics: TouchZoneMetrics
    ) -> LayoutChainResolver.Outcome {
        let manifest = ControlsManifestLoader.load(gameRoot: gameRoot, metrics: metrics)?
            .result.manifest
        return resolve(
            pin: pin, gameLayoutOccupied: manifest?.touch != nil, store: store,
            defaultProfileName: defaultProfileName)
    }
}
