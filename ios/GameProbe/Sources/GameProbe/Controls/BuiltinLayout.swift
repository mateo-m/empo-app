// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

public enum BuiltinLayout {
    public struct Key: Equatable, Sendable {
        public var label: String
        /// nil for a key that has no code. Its button is left out, and
        /// the other buttons keep their places.
        public var code: String?

        public init(label: String, code: String?) {
            self.label = label
            self.code = code
        }
    }

    public static func dpad(isLandscape: Bool) -> DPadSpec {
        DPadSpec(
            x: isLandscape ? 0.10 : 0.13,
            y: isLandscape ? 0.65 : 0.72,
            size: ControlLimits.defaultDPadSize,
            opacity: 1)
    }

    /// A sideways screen is shorter and wider, so its grid sits higher
    /// and further apart.
    public static func buttonCenters(isLandscape: Bool) -> [(x: Double, y: Double)] {
        isLandscape
            ? [(0.80, 0.59), (0.88, 0.59), (0.80, 0.75), (0.88, 0.75)]
            : [(0.70, 0.67), (0.88, 0.67), (0.70, 0.76), (0.88, 0.76)]
    }

    public static func layout(keys: [Key], isLandscape: Bool) -> TouchLayout {
        TouchLayout(
            dpad: dpad(isLandscape: isLandscape),
            buttons: zip(keys, buttonCenters(isLandscape: isLandscape)).compactMap { key, center in
                key.code.map {
                    ButtonSpec(
                        label: key.label, key: $0, x: center.x, y: center.y,
                        size: ControlLimits.defaultButtonSize, opacity: 1)
                }
            },
            actionButtons: [])
    }
}
