// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum ButtonSeparation {
    public static let minimumGap: Double = 2
    /// A new value changes derived layouts, and with them the hashes in
    /// the migration record.
    public static let maxIterations: Int = 24

    /// Steps of the golden angle (in radians) never repeat a
    /// direction, so buttons on one point part in different ways.
    private static let goldenAngle = 2.399_963_229_728_653

    /// All values are in points. Obstacles and walls stay fixed. Only
    /// buttons move.
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
                        neighbors: positions.indices.filter { $0 != index }.map {
                            (x: positions[$0].x, y: positions[$0].y, size: buttons[$0].size)
                        },
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
        guard
            let overlap = overlap(
                from: positions[i], to: positions[j],
                required: (sizeI + sizeJ) * 0.5 + minimumGap, seed: i + 1)
        else { return }

        let pushX = overlap.x * overlap.depth * 0.5
        let pushY = overlap.y * overlap.depth * 0.5

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
        guard
            let overlap = overlap(
                from: (obstacle.x, obstacle.y), to: positions[buttonIndex],
                required: (buttonSize + obstacle.size) * 0.5 + minimumGap,
                seed: buttonIndex + 1 + obstacleIndex)
        else { return }

        positions[buttonIndex].x += overlap.x * overlap.depth
        positions[buttonIndex].y += overlap.y * overlap.depth
        moved = true
    }

    private static func overlap(
        from a: (x: Double, y: Double), to b: (x: Double, y: Double),
        required: Double, seed: Int
    ) -> (x: Double, y: Double, depth: Double)? {
        var dx = b.x - a.x
        var dy = b.y - a.y
        var dist = hypot(dx, dy)
        if dist < 1e-9 {
            let angle = Double(seed) * goldenAngle
            dx = cos(angle) * 1e-3
            dy = sin(angle) * 1e-3
            dist = hypot(dx, dy)
        }
        guard dist < required else { return nil }
        return (dx / dist, dy / dist, required - dist)
    }

    /// An exit onto an obstacle or a neighbor pushes the button
    /// straight back in. A point clear of the obstacles only comes
    /// next, because neighbors can move apart later and obstacles
    /// cannot.
    private static func pushOutOfWall(
        index: Int,
        wall: EditDragSolver.Rect,
        buttonSize: Double,
        width: Double,
        height: Double,
        obstacles: [(x: Double, y: Double, size: Double)],
        neighbors: [(x: Double, y: Double, size: Double)],
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

        func isClear(
            _ exit: (x: Double, y: Double), of circles: [(x: Double, y: Double, size: Double)]
        ) -> Bool {
            circles.allSatisfy {
                hypot(exit.x - $0.x, exit.y - $0.y) >= (buttonSize + $0.size) * 0.5 + minimumGap - 1e-9
            }
        }
        func distanceFromPoint(_ exit: (x: Double, y: Double)) -> Double {
            hypot(exit.x - point.x, exit.y - point.y)
        }

        // On an edge, each blocker blocks one interval. Thus the
        // nearest clear point is the projection of the point or an end
        // of a blocked interval.
        var direct: [(x: Double, y: Double)] = []
        var candidates: [(x: Double, y: Double)] = []
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
            candidates.append(projection)
            for blocker in obstacles + neighbors {
                let reach = (buttonSize + blocker.size) * 0.5 + minimumGap
                let offset = abs(edge.fixed - (edge.vertical ? blocker.x : blocker.y))
                guard offset < reach else { continue }
                let span = (reach * reach - offset * offset).squareRoot()
                let center = edge.vertical ? blocker.y : blocker.x
                candidates += [center - span, center + span].filter { $0 >= low && $0 <= high }.map(toPoint)
            }
        }
        let clearOfObstacles = candidates.filter { isClear($0, of: obstacles) }
        let clear = clearOfObstacles.filter { isClear($0, of: neighbors) }

        let nearest = { (exits: [(x: Double, y: Double)]) in
            exits.min { distanceFromPoint($0) < distanceFromPoint($1) }
        }
        guard let exit = nearest(clear) ?? nearest(clearOfObstacles) ?? nearest(direct) else { return }
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

        let angle = Double(index + 1) * goldenAngle
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
