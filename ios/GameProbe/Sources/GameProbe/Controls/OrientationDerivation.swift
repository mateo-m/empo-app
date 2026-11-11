// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum OrientationDerivation {
    /// When `source` has no d-pad, the buttons move clear of
    /// `defaultDpad`, the d-pad that the target orientation shows.
    public static func derive(
        from source: TouchLayout,
        sourceIsLandscape: Bool,
        metrics: TouchZoneMetrics,
        defaultDpad: DPadSpec?
    ) -> TouchLayout {
        let targetIsLandscape = !sourceIsLandscape
        let targetWidth = metrics.width(isLandscape: targetIsLandscape)
        let targetHeight = metrics.height(isLandscape: targetIsLandscape)

        func mappedCenter(x: Double, y: Double, size: Double) -> (x: Double, y: Double) {
            mapCenter(
                x: x, y: y, size: size, metrics: metrics, sourceIsLandscape: sourceIsLandscape)
        }
        func fraction(_ point: (x: Double, y: Double)) -> (x: Double, y: Double) {
            (
                ControlLimits.placedCoordinate.clamp(point.x / targetWidth),
                ControlLimits.placedCoordinate.clamp(point.y / targetHeight)
            )
        }

        var derivedDpad: DPadSpec?
        var dpadObstacle: (x: Double, y: Double, size: Double)?
        if let spec = source.dpad {
            let size = spec.size ?? ControlLimits.defaultDPadSize
            let center = mappedCenter(x: spec.x, y: spec.y, size: size)
            let placed = fraction(center)
            derivedDpad = DPadSpec(
                x: placed.x, y: placed.y, size: size, opacity: spec.opacity, style: spec.style)
            dpadObstacle = (center.x, center.y, size)
        } else if let defaultDpad {
            dpadObstacle = (
                defaultDpad.x * targetWidth, defaultDpad.y * targetHeight,
                defaultDpad.size ?? ControlLimits.defaultDPadSize
            )
        }

        enum TaggedSpec {
            case key(ButtonSpec)
            case action(ActionButtonSpec)
        }
        let tagged =
            (source.buttons ?? []).map(TaggedSpec.key)
            + (source.actionButtons ?? []).map(TaggedSpec.action)
        let inputs = tagged.map { spec -> (x: Double, y: Double, size: Double) in
            let (x, y, size) =
                switch spec {
                case .key(let button): (button.x, button.y, button.size)
                case .action(let button): (button.x, button.y, button.size)
                }
            let resolvedSize = size ?? ControlLimits.defaultButtonSize
            let center = mappedCenter(x: x, y: y, size: resolvedSize)
            return (center.x, center.y, resolvedSize)
        }
        let positions =
            inputs.isEmpty
            ? []
            : ButtonSeparation.separate(
                inputs, width: targetWidth, height: targetHeight,
                obstacles: dpadObstacle.map { [$0] } ?? []
            ).positions

        var derivedButtons: [ButtonSpec] = []
        var derivedActionButtons: [ActionButtonSpec] = []
        for (spec, position) in zip(tagged, positions) {
            let placed = fraction(position)
            switch spec {
            case .key(let button):
                derivedButtons.append(
                    ButtonSpec(
                        label: button.label, key: button.key, x: placed.x, y: placed.y,
                        size: button.size ?? ControlLimits.defaultButtonSize,
                        opacity: button.opacity))
            case .action(let button):
                derivedActionButtons.append(
                    ActionButtonSpec(
                        action: button.action, x: placed.x, y: placed.y,
                        size: button.size ?? ControlLimits.defaultButtonSize,
                        opacity: button.opacity))
            }
        }

        return TouchLayout(
            dpad: derivedDpad,
            buttons: source.buttons.map { _ in derivedButtons },
            actionButtons: source.actionButtons.map { _ in derivedActionButtons }
        )
    }

    /// A control on the left half keeps its distance from the left
    /// edge of the safe area, and a control on the right half from the
    /// right edge. All controls keep their distance from the bottom.
    private static func mapCenter(
        x fractionX: Double,
        y fractionY: Double,
        size: Double,
        metrics: TouchZoneMetrics,
        sourceIsLandscape: Bool
    ) -> (x: Double, y: Double) {
        let source = sourceIsLandscape
        let target = !sourceIsLandscape
        let sourceWidth = metrics.width(isLandscape: source)
        let sourceHeight = metrics.height(isLandscape: source)
        let targetWidth = metrics.width(isLandscape: target)
        let targetHeight = metrics.height(isLandscape: target)

        let sourceX = fractionX * sourceWidth
        let sourceY = fractionY * sourceHeight

        let targetX =
            sourceX < sourceWidth * 0.5
            ? metrics.leadingInset(isLandscape: target)
                + (sourceX - metrics.leadingInset(isLandscape: source))
            : (targetWidth - metrics.trailingInset(isLandscape: target))
                - (sourceWidth - metrics.trailingInset(isLandscape: source) - sourceX)
        let offsetFromBottom = (sourceHeight - metrics.bottomInset(isLandscape: source)) - sourceY
        let targetY = (targetHeight - metrics.bottomInset(isLandscape: target)) - offsetFromBottom

        let half = size * 0.5
        let minX = metrics.leadingInset(isLandscape: target) + half
        let maxX = max(minX, targetWidth - metrics.trailingInset(isLandscape: target) - half)
        let minY = metrics.topInset(isLandscape: target) + half
        let maxY = max(minY, targetHeight - metrics.bottomInset(isLandscape: target) - half)
        return (min(max(targetX, minX), maxX), min(max(targetY, minY), maxY))
    }
}
