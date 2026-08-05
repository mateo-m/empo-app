import Foundation

public enum OrientationDerivation {
    static let coordMin: Double = 0.02
    static let coordMax: Double = 0.98

    /// Derives the layout of the missing orientation from `source`.
    /// It keeps the arrangement in point space.
    public static func derive(
        from source: TouchLayout,
        sourceIsLandscape: Bool,
        metrics: TouchZoneMetrics,
        defaultDpad: (x: Double, y: Double, size: Double)? = nil
    ) -> TouchLayout {
        let targetIsLandscape = !sourceIsLandscape

        let sourceWidth = metrics.width(isLandscape: sourceIsLandscape)
        let sourceHeight = metrics.height(isLandscape: sourceIsLandscape)
        let targetWidth = metrics.width(isLandscape: targetIsLandscape)
        let targetHeight = metrics.height(isLandscape: targetIsLandscape)

        let sourceLeading = metrics.leadingInset(isLandscape: sourceIsLandscape)
        let sourceTrailing = metrics.trailingInset(isLandscape: sourceIsLandscape)
        let sourceTop = metrics.topInset(isLandscape: sourceIsLandscape)
        let sourceBottom = metrics.bottomInset(isLandscape: sourceIsLandscape)

        let targetLeading = metrics.leadingInset(isLandscape: targetIsLandscape)
        let targetTrailing = metrics.trailingInset(isLandscape: targetIsLandscape)
        let targetTop = metrics.topInset(isLandscape: targetIsLandscape)
        let targetBottom = metrics.bottomInset(isLandscape: targetIsLandscape)

        var derivedDpad: DPadSpec?
        var dpadObstacle: (x: Double, y: Double, size: Double)?

        if let spec = source.dpad {
            let size = spec.size ?? 140
            let center = mapCenter(
                fractionX: spec.x,
                fractionY: spec.y,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceLeading: sourceLeading,
                sourceTrailing: sourceTrailing,
                sourceTop: sourceTop,
                sourceBottom: sourceBottom,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                targetLeading: targetLeading,
                targetTrailing: targetTrailing,
                targetTop: targetTop,
                targetBottom: targetBottom,
                elementSize: size
            )
            derivedDpad = DPadSpec(
                x: 0, y: 0, size: size, opacity: spec.opacity, style: spec.style
            )
            dpadObstacle = (center.x, center.y, size)
        } else if let defaultDpad {
            dpadObstacle = defaultDpad
        }

        var derivedButtons: [ButtonSpec]?
        var derivedActionButtons: [ActionButtonSpec]?
        var buttonInputs: [(x: Double, y: Double, size: Double)] = []
        var buttonSpecs: [ButtonSpec] = []
        var actionButtonSpecs: [ActionButtonSpec] = []

        func mappedCenter(x: Double, y: Double, size: Double) -> (x: Double, y: Double) {
            mapCenter(
                fractionX: x,
                fractionY: y,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceLeading: sourceLeading,
                sourceTrailing: sourceTrailing,
                sourceTop: sourceTop,
                sourceBottom: sourceBottom,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                targetLeading: targetLeading,
                targetTrailing: targetTrailing,
                targetTop: targetTop,
                targetBottom: targetBottom,
                elementSize: size
            )
        }

        if let buttons = source.buttons {
            derivedButtons = []
            for spec in buttons {
                let size = spec.size ?? 56
                let center = mappedCenter(x: spec.x, y: spec.y, size: size)
                buttonInputs.append((center.x, center.y, size))
                buttonSpecs.append(spec)
            }
        }

        if let actionButtons = source.actionButtons {
            derivedActionButtons = []
            for spec in actionButtons {
                let size = spec.size ?? 56
                let center = mappedCenter(x: spec.x, y: spec.y, size: size)
                buttonInputs.append((center.x, center.y, size))
                actionButtonSpecs.append(spec)
            }
        }

        if !buttonInputs.isEmpty {
            let obstacles = dpadObstacle.map { [$0] } ?? []
            let separated = ButtonSeparation.separate(
                buttonInputs,
                width: targetWidth,
                height: targetHeight,
                obstacles: obstacles
            )

            // Separation input order is buttons, then action buttons.
            var separatedButtons: [ButtonSpec] = []
            for (index, spec) in buttonSpecs.enumerated() {
                let point = separated.positions[index]
                let size = spec.size ?? 56
                separatedButtons.append(
                    ButtonSpec(
                        label: spec.label,
                        key: spec.key,
                        x: clampFraction(point.x / targetWidth),
                        y: clampFraction(point.y / targetHeight),
                        size: size,
                        opacity: spec.opacity
                    )
                )
            }
            if source.buttons != nil {
                derivedButtons = separatedButtons
            }

            var separatedActionButtons: [ActionButtonSpec] = []
            for (index, spec) in actionButtonSpecs.enumerated() {
                let point = separated.positions[buttonSpecs.count + index]
                let size = spec.size ?? 56
                separatedActionButtons.append(
                    ActionButtonSpec(
                        action: spec.action,
                        x: clampFraction(point.x / targetWidth),
                        y: clampFraction(point.y / targetHeight),
                        size: size,
                        opacity: spec.opacity
                    )
                )
            }
            if source.actionButtons != nil {
                derivedActionButtons = separatedActionButtons
            }
        }

        if var dpad = derivedDpad, let obstacle = dpadObstacle {
            dpad.x = clampFraction(obstacle.x / targetWidth)
            dpad.y = clampFraction(obstacle.y / targetHeight)
            derivedDpad = dpad
        }

        return TouchLayout(
            dpad: derivedDpad,
            buttons: derivedButtons,
            actionButtons: derivedActionButtons
        )
    }

    private static func mapCenter(
        fractionX: Double,
        fractionY: Double,
        sourceWidth: Double,
        sourceHeight: Double,
        sourceLeading: Double,
        sourceTrailing: Double,
        sourceTop: Double,
        sourceBottom: Double,
        targetWidth: Double,
        targetHeight: Double,
        targetLeading: Double,
        targetTrailing: Double,
        targetTop: Double,
        targetBottom: Double,
        elementSize: Double
    ) -> (x: Double, y: Double) {
        let sourceCenterX = fractionX * sourceWidth
        let sourceCenterY = fractionY * sourceHeight

        let targetX: Double
        if sourceCenterX < sourceWidth * 0.5 {
            let offsetFromLeft = sourceCenterX - sourceLeading
            targetX = targetLeading + offsetFromLeft
        } else {
            let offsetFromRight = (sourceWidth - sourceTrailing) - sourceCenterX
            targetX = (targetWidth - targetTrailing) - offsetFromRight
        }

        let offsetFromBottom = (sourceHeight - sourceBottom) - sourceCenterY
        let targetY = (targetHeight - targetBottom) - offsetFromBottom

        return clampInZone(
            x: targetX,
            y: targetY,
            size: elementSize,
            width: targetWidth,
            height: targetHeight,
            leading: targetLeading,
            trailing: targetTrailing,
            top: targetTop,
            bottom: targetBottom
        )
    }

    private static func clampInZone(
        x: Double,
        y: Double,
        size: Double,
        width: Double,
        height: Double,
        leading: Double,
        trailing: Double,
        top: Double,
        bottom: Double
    ) -> (x: Double, y: Double) {
        let half = size * 0.5
        let minX = leading + half
        let maxX = max(minX, width - trailing - half)
        let minY = top + half
        let maxY = max(minY, height - bottom - half)
        return (
            min(max(x, minX), maxX),
            min(max(y, minY), maxY)
        )
    }

    private static func clampFraction(_ value: Double) -> Double {
        min(max(value, coordMin), coordMax)
    }
}
