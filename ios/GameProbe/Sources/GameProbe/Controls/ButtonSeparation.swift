// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum ButtonSeparation {
    public static let minimumGap: Double = 2
    public static let maxIterations: Int = 24

    /// Separates intersecting circles in point space, one step at a
    /// time. Returns the adjusted centers and how many buttons moved
    /// from their inputs. Obstacles are fixed circles (for example,
    /// the d-pad). Walls are fixed rectangles no button may overlap
    /// (for example, a toolbar column). Only buttons move.
    public static func separate(
        _ buttons: [(x: Double, y: Double, size: Double)],
        width: Double,
        height: Double,
        obstacles: [(x: Double, y: Double, size: Double)] = [],
        walls: [EditDragSolver.Rect] = []
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
                for wall in walls {
                    pushOutOfWall(
                        index: index, wall: wall, buttonSize: buttons[index].size,
                        width: width, height: height, obstacles: obstacles,
                        positions: &positions, moved: &moved)
                }
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

    /// Leaves to the nearest point on the wall's outline that keeps
    /// the button in bounds and clear of every obstacle. An exit onto
    /// an obstacle would let the obstacle push it straight back in.
    /// Without a clear point, the nearest direct exit in bounds wins.
    /// Without any, the button stays where the bounds clamp put it.
    private static func pushOutOfWall(
        index: Int,
        wall: EditDragSolver.Rect,
        buttonSize: Double,
        width: Double,
        height: Double,
        obstacles: [(x: Double, y: Double, size: Double)],
        positions: inout [(x: Double, y: Double)],
        moved: inout Bool
    ) {
        let half = buttonSize * 0.5
        let point = positions[index]
        let minX = wall.x - half
        let maxX = wall.x + wall.width + half
        let minY = wall.y - half
        let maxY = wall.y + wall.height + half
        guard point.x > minX, point.x < maxX, point.y > minY, point.y < maxY else { return }

        func isClear(_ exit: (x: Double, y: Double)) -> Bool {
            obstacles.allSatisfy {
                hypot(exit.x - $0.x, exit.y - $0.y) >= (buttonSize + $0.size) * 0.5 + minimumGap - 1e-9
            }
        }
        func distanceFromPoint(_ exit: (x: Double, y: Double)) -> Double {
            hypot(exit.x - point.x, exit.y - point.y)
        }

        // Each outline edge clipped to bounds. On an edge, an obstacle
        // blocks one interval, so the nearest clear point is the
        // point's own projection or the end of a blocked interval.
        var direct: [(x: Double, y: Double)] = []
        var clear: [(x: Double, y: Double)] = []
        let edges: [(fixed: Double, vertical: Bool)] = [
            (minX, true), (maxX, true), (minY, false), (maxY, false),
        ]
        for edge in edges {
            let fixedLimit = edge.vertical ? width : height
            let freeLimit = edge.vertical ? height : width
            guard edge.fixed >= half, edge.fixed <= fixedLimit - half else { continue }
            let low = max(edge.vertical ? minY : minX, half)
            let high = min(edge.vertical ? maxY : maxX, freeLimit - half)
            guard low <= high else { continue }
            let toPoint = { (free: Double) -> (x: Double, y: Double) in
                edge.vertical ? (x: edge.fixed, y: free) : (x: free, y: edge.fixed)
            }
            let projection = toPoint(min(max(edge.vertical ? point.y : point.x, low), high))
            direct.append(projection)
            var candidates = [projection]
            for obstacle in obstacles {
                let reach = (buttonSize + obstacle.size) * 0.5 + minimumGap
                let offset = abs(edge.fixed - (edge.vertical ? obstacle.x : obstacle.y))
                guard offset < reach else { continue }
                let span = (reach * reach - offset * offset).squareRoot()
                let center = edge.vertical ? obstacle.y : obstacle.x
                candidates += [center - span, center + span].filter { $0 >= low && $0 <= high }.map(toPoint)
            }
            clear += candidates.filter(isClear)
        }

        let nearest = { (exits: [(x: Double, y: Double)]) in
            exits.min { distanceFromPoint($0) < distanceFromPoint($1) }
        }
        guard let exit = nearest(clear) ?? nearest(direct) else { return }
        positions[index] = exit
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
