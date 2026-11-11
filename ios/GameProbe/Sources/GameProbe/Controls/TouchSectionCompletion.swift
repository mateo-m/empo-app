// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum TouchSectionCompletion {
    /// An explicit `{}` counts as a present orientation, so the function
    /// does not derive it.
    public static func complete(
        _ section: TouchSection,
        metrics: TouchZoneMetrics
    ) -> (section: TouchSection, involvedDerivation: Bool) {
        switch (section.portrait, section.landscape) {
        case (let portrait?, nil):
            let landscape = OrientationDerivation.derive(
                from: portrait, sourceIsLandscape: false, metrics: metrics,
                defaultDpad: BuiltinLayout.dpad(isLandscape: true))
            return (TouchSection(portrait: portrait, landscape: landscape), true)
        case (nil, let landscape?):
            let portrait = OrientationDerivation.derive(
                from: landscape, sourceIsLandscape: true, metrics: metrics,
                defaultDpad: BuiltinLayout.dpad(isLandscape: false))
            return (TouchSection(portrait: portrait, landscape: landscape), true)
        default:
            return (section, false)
        }
    }
}
