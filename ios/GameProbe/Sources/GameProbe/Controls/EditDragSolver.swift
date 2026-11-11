// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum EditDragSolver {
    public struct Circle: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double

        public init(x: Double, y: Double, radius: Double) {
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }

        func inset(by amount: Double) -> Rect {
            Rect(
                x: x + amount, y: y + amount,
                width: width - 2 * amount, height: height - 2 * amount)
        }

        func contains(_ px: Double, _ py: Double) -> Bool {
            px >= x && px <= maxX && py >= y && py <= maxY
        }
    }

    /// The push-out lands exactly on the rim. This slack stops float
    /// noise from reading as a collision.
    public static let rimSlack = 0.5

    public static func collides(
        x: Double, y: Double, radius: Double,
        obstacles: [Circle], walls: [Rect]
    ) -> Bool {
        let circleHit = obstacles.contains { obstacle in
            let dx = x - obstacle.x
            let dy = y - obstacle.y
            let minDistance = radius + obstacle.radius - rimSlack
            return dx * dx + dy * dy < minDistance * minDistance
        }
        if circleHit { return true }
        return walls.contains { wall in
            wall.inset(by: -(radius - rimSlack)).contains(x, y)
        }
    }

    /// A push out of one obstacle can push into another, so the passes
    /// repeat. Three passes are enough, because a drag sends many events
    /// each second, and each one continues from this result.
    ///
    /// `previous` keeps the circle on the side it came from. Without it,
    /// a pointer that crosses the center of an obstacle pops the circle
    /// through to the far side.
    public static func resolvedCenter(
        desiredX: Double, desiredY: Double,
        previousX: Double?, previousY: Double?,
        radius: Double, obstacles: [Circle], walls: [Rect]
    ) -> (x: Double, y: Double) {
        var x = desiredX
        var y = desiredY
        for _ in 0..<3 {
            var moved = false
            for obstacle in obstacles {
                var dx = x - obstacle.x
                var dy = y - obstacle.y
                let minDistance = radius + obstacle.radius
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < minDistance * minDistance else { continue }
                if let previousX, let previousY {
                    // `<=` includes a pointer exactly on the center.
                    // There, the up-push fallback lets the circle
                    // tunnel through.
                    let approachX = previousX - obstacle.x
                    let approachY = previousY - obstacle.y
                    if approachX != 0 || approachY != 0,
                        dx * approachX + dy * approachY <= 0
                    {
                        dx = approachX
                        dy = approachY
                    }
                }
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < 0.001 {
                    // Any stable direction works here.
                    x = obstacle.x
                    y = obstacle.y - minDistance
                } else {
                    x = obstacle.x + dx / distance * minDistance
                    y = obstacle.y + dy / distance * minDistance
                }
                moved = true
            }
            for wall in walls {
                if let pushed = rectPushOut(
                    x: x, y: y, radius: radius, wall: wall,
                    previousX: previousX, previousY: previousY)
                {
                    x = pushed.x
                    y = pushed.y
                    moved = true
                }
            }
            if !moved { break }
        }
        return (x, y)
    }

    static func rectPushOut(
        x: Double, y: Double, radius: Double, wall: Rect,
        previousX: Double?, previousY: Double?
    ) -> (x: Double, y: Double)? {
        let inflated = wall.inset(by: -radius)
        guard inflated.contains(x, y) else { return nil }
        if let previousX, let previousY, !inflated.contains(previousX, previousY) {
            if previousX <= inflated.x { return (inflated.x, y) }
            if previousX >= inflated.maxX { return (inflated.maxX, y) }
            if previousY <= inflated.y { return (x, inflated.y) }
            return (x, inflated.maxY)
        }
        let exits: [(distance: Double, x: Double, y: Double)] = [
            (x - inflated.x, inflated.x, y),
            (inflated.maxX - x, inflated.maxX, y),
            (y - inflated.y, x, inflated.y),
            (inflated.maxY - y, x, inflated.maxY),
        ]
        let best = exits.min { $0.distance < $1.distance }
        return best.map { ($0.x, $0.y) }
    }
}
