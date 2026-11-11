// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/// The loader rejects a value outside these limits. Each writer clamps
/// to them, so that its output loads.
public enum ControlLimits {
    public static let maxFileSize = 128 * 1024
    public static let maxFileSizeText = "128 KiB"
    /// This limit counts key buttons and action buttons together, in
    /// one orientation.
    public static let maxButtonsPerOrientation = 21
    public static let maxLabelLength = 8

    public static let coordinate: ClosedRange<Double> = 0...1
    public static let buttonSize: ClosedRange<Double> = 40...100
    public static let dpadSize: ClosedRange<Double> = 100...200
    public static let opacity: ClosedRange<Double> = 0.2...1

    public static let defaultButtonSize: Double = 56
    public static let defaultDPadSize: Double = 140

    /// A translated or derived control keeps this margin from the
    /// screen edge, so that a finger can still reach all of it.
    public static let placedCoordinate: ClosedRange<Double> = 0.02...0.98
}

extension ClosedRange {
    public func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

enum TranslatorLayout {
    static let cellGap: Double = 14
    static let edgeMargin: Double = 16

    /// The lower bound wins when the bounds cross, so a control that
    /// does not fit keeps its margin from the leading or top edge.
    static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.max(minimum, Swift.min(maximum, value))
    }
}
