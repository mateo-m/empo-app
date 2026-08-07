import Foundation

/// Rigid collision solver for edit-mode control drags. The dragged
/// circle cannot enter its neighbors or the edit-chrome rectangles —
/// they act as walls and the drag slides along their rims. Neighbors
/// never move; there is no momentum and no physics engine.
///
/// Pure geometry in the same Double coordinate style as
/// `ButtonSeparation`, so it tests on Linux CI. The app layer builds
/// the obstacle list (its clamping lives there) and maps CGFloat in
/// and out.
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

    /// Tolerance at the rim: the push-out lands exactly on it and
    /// float noise must not read as a collision.
    public static let rimSlack = 0.5

    /// True when a circle at `(x, y)` with `radius` intersects any
    /// obstacle circle or wall rectangle.
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

    /// Push `desired` out of every obstacle, iterated a few times so
    /// settling between two obstacles converges. `previous` (the last
    /// resolved center this drag) keeps the circle on its approach
    /// side: without it, the pointer crossing an obstacle's center
    /// pops the circle through to the far side.
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
                    // The pointer reached or crossed the obstacle's
                    // center: push out toward the side the drag came
                    // from, not toward the pointer's side. <= covers
                    // the pointer sitting exactly ON the center —
                    // the up-push fallback there would hand the side
                    // memory a stray direction and let the circle
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
                    // Dead center: push straight up, any stable
                    // direction works.
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

    /// Circle-vs-rect push-out. nil when there is no collision.
    /// Inside the inflated rect, the exit side prefers where the
    /// drag came from, matching the circle obstacles' side memory.
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
