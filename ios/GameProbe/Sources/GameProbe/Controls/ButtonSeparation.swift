import Foundation

public enum ButtonSeparation {
    public static let minimumGap: Double = 2
    public static let maxIterations: Int = 24

    /// Iteratively separates intersecting circles in point space.
    /// Returns adjusted centers and how many buttons moved from their inputs.
    /// Obstacles are fixed circles (e.g. the d-pad); only buttons move.
    public static func separate(
        _ buttons: [(x: Double, y: Double, size: Double)],
        width: Double,
        height: Double,
        obstacles: [(x: Double, y: Double, size: Double)] = []
    ) -> (positions: [(x: Double, y: Double)], movedCount: Int) {
        guard !buttons.isEmpty, width > 0, height > 0 else {
            return (buttons.map { ($0.x, $0.y) }, 0)
        }

        var positions = buttons.enumerated().map { index, button -> (x: Double, y: Double) in
            nudgeIdentical(button: button, index: index, buttons: buttons)
        }

        for _ in 0..<maxIterations {
            var moved = false
            for i in 0..<positions.count {
                for j in (i + 1)..<positions.count {
                    separatePair(
                        i: i, j: j,
                        positions: &positions,
                        sizeI: buttons[i].size,
                        sizeJ: buttons[j].size,
                        moved: &moved
                    )
                }

                for (obstacleIndex, obstacle) in obstacles.enumerated() {
                    pushAwayFromObstacle(
                        buttonIndex: i,
                        obstacle: obstacle,
                        obstacleIndex: obstacleIndex,
                        buttonSize: buttons[i].size,
                        positions: &positions,
                        moved: &moved
                    )
                }
            }

            for index in positions.indices {
                positions[index] = clamp(
                    positions[index],
                    size: buttons[index].size,
                    width: width,
                    height: height
                )
            }

            if !moved { break }
        }

        var movedCount = 0
        for (index, original) in buttons.enumerated() {
            let adjusted = positions[index]
            if abs(adjusted.x - original.x) > 1e-6 || abs(adjusted.y - original.y) > 1e-6 {
                movedCount += 1
            }
        }

        return (positions, movedCount)
    }

    private static func separatePair(
        i: Int,
        j: Int,
        positions: inout [(x: Double, y: Double)],
        sizeI: Double,
        sizeJ: Double,
        moved: inout Bool
    ) {
        let required = (sizeI + sizeJ) * 0.5 + minimumGap

        var dx = positions[j].x - positions[i].x
        var dy = positions[j].y - positions[i].y
        var dist = hypot(dx, dy)

        if dist < 1e-9 {
            let angle = Double(i + 1) * 2.399_963_229_728_653
            dx = cos(angle) * 1e-3
            dy = sin(angle) * 1e-3
            dist = hypot(dx, dy)
        }

        guard dist < required else { return }

        let penetration = required - dist
        let pushX = dx / dist * penetration * 0.5
        let pushY = dy / dist * penetration * 0.5

        positions[i].x -= pushX
        positions[i].y -= pushY
        positions[j].x += pushX
        positions[j].y += pushY
        moved = true
    }

    private static func pushAwayFromObstacle(
        buttonIndex: Int,
        obstacle: (x: Double, y: Double, size: Double),
        obstacleIndex: Int,
        buttonSize: Double,
        positions: inout [(x: Double, y: Double)],
        moved: inout Bool
    ) {
        let required = (buttonSize + obstacle.size) * 0.5 + minimumGap

        var dx = positions[buttonIndex].x - obstacle.x
        var dy = positions[buttonIndex].y - obstacle.y
        var dist = hypot(dx, dy)

        if dist < 1e-9 {
            let angle = Double(buttonIndex + 1 + obstacleIndex) * 2.399_963_229_728_653
            dx = cos(angle) * 1e-3
            dy = sin(angle) * 1e-3
            dist = hypot(dx, dy)
        }

        guard dist < required else { return }

        let penetration = required - dist
        positions[buttonIndex].x += dx / dist * penetration
        positions[buttonIndex].y += dy / dist * penetration
        moved = true
    }

    private static func nudgeIdentical(
        button: (x: Double, y: Double, size: Double),
        index: Int,
        buttons: [(x: Double, y: Double, size: Double)]
    ) -> (x: Double, y: Double) {
        let duplicates = buttons.enumerated().filter {
            abs($0.element.x - button.x) < 1e-9 && abs($0.element.y - button.y) < 1e-9
        }
        guard duplicates.count > 1 else { return (button.x, button.y) }

        let angle = Double(index + 1) * 2.399_963_229_728_653
        let epsilon = 0.5
        return (
            button.x + cos(angle) * epsilon,
            button.y + sin(angle) * epsilon
        )
    }

    private static func clamp(
        _ point: (x: Double, y: Double),
        size: Double,
        width: Double,
        height: Double
    ) -> (x: Double, y: Double) {
        let half = size * 0.5
        let minX = half
        let maxX = max(half, width - half)
        let minY = half
        let maxY = max(half, height - half)
        return (
            min(max(point.x, minX), maxX),
            min(max(point.y, minY), maxY)
        )
    }
}
