// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/// RPG Maker games draw at 4:3. A layout uses `typical` when the
/// engine has not reported the game size yet.
public enum GameAspect {
    public static let typical: Double = 4.0 / 3.0

    public static func fit(
        width: Double, height: Double, aspect: Double = typical
    ) -> (width: Double, height: Double) {
        let fittedWidth = min(width, height * aspect)
        return (fittedWidth, fittedWidth / aspect)
    }
}
