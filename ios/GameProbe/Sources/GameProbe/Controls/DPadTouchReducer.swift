// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Each returned array lists all releases before any press. Callers
/// must inject the edges in array order, so that a finger that moves
/// between wedges never holds opposite directions.
///
/// A direction stays held while a live touch resolves to it, so the
/// host must report every lift. UIKit can drop a touch end, for example
/// when the control is disabled. Then the host closes the touch itself.
public struct DPadTouchReducer: Sendable {
    public struct DirectionSet: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public static let up = DirectionSet(rawValue: 1 << 0)
        public static let down = DirectionSet(rawValue: 1 << 1)
        public static let left = DirectionSet(rawValue: 1 << 2)
        public static let right = DirectionSet(rawValue: 1 << 3)

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The angle comes from atan2 in view space, where +y points
        /// down.
        public init(angle: Double) {
            let a = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let s = Double.pi / 8
            switch a {
            case (15 * s)..<(2 * .pi), 0..<s: self = .right
            case s..<(3 * s): self = [.right, .down]
            case (3 * s)..<(5 * s): self = .down
            case (5 * s)..<(7 * s): self = [.down, .left]
            case (7 * s)..<(9 * s): self = .left
            case (9 * s)..<(11 * s): self = [.left, .up]
            case (11 * s)..<(13 * s): self = .up
            case (13 * s)..<(15 * s): self = [.up, .right]
            default: self = []
            }
        }

        public init(cardinalAngle angle: Double) {
            let a = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let s = Double.pi / 4
            switch a {
            case (7 * s)..<(2 * .pi), 0..<s: self = .right
            case s..<(3 * s): self = .down
            case (3 * s)..<(5 * s): self = .left
            case (5 * s)..<(7 * s): self = .up
            default: self = []
            }
        }

        public func contains(_ direction: ControlDirection) -> Bool {
            switch direction {
            case .up: return rawValue & DirectionSet.up.rawValue != 0
            case .down: return rawValue & DirectionSet.down.rawValue != 0
            case .left: return rawValue & DirectionSet.left.rawValue != 0
            case .right: return rawValue & DirectionSet.right.rawValue != 0
            }
        }

        /// The case order of `ControlDirection` sets the edge order.
        public var directions: [ControlDirection] {
            ControlDirection.allCases.filter { contains($0) }
        }
    }

    public struct Edge: Equatable, Sendable {
        public let direction: ControlDirection
        public let pressed: Bool

        public init(direction: ControlDirection, pressed: Bool) {
            self.direction = direction
            self.pressed = pressed
        }
    }

    public static let defaultDeadZoneRatio = 0.2
    public static let defaultCardinalOnlyRadiusRatio = 0.5
    public static let defaultSlideOffMargin = 30.0

    public private(set) var active: DirectionSet = []

    private struct Touch {
        let id: Int
        var x: Double
        var y: Double
        var directions: DirectionSet
    }

    private var touches: [Touch] = []

    public init() {}

    /// The joystick nub follows the oldest touch, so that it does not
    /// jump between two fingers.
    public var leadTouchPoint: (x: Double, y: Double)? {
        touches.first.map { ($0.x, $0.y) }
    }

    /// `x` and `y` are in the space of the D-pad, with +y down. Each
    /// sample carries `size`, so that a resize during a touch uses the
    /// new geometry.
    public mutating func touchChanged(
        touch id: Int,
        x: Double,
        y: Double,
        size: Double,
        deadZoneRatio: Double = defaultDeadZoneRatio,
        cardinalOnlyRadiusRatio: Double = defaultCardinalOnlyRadiusRatio,
        slideOffMargin: Double = defaultSlideOffMargin
    ) -> [Edge] {
        let directions = Self.directions(
            x: x, y: y, size: size,
            deadZoneRatio: deadZoneRatio,
            cardinalOnlyRadiusRatio: cardinalOnlyRadiusRatio,
            slideOffMargin: slideOffMargin
        )
        let touch = Touch(id: id, x: x, y: y, directions: directions)
        if let index = touches.firstIndex(where: { $0.id == id }) {
            touches[index] = touch
        } else {
            touches.append(touch)
        }
        return diff(to: union)
    }

    public mutating func touchChanged(
        touch id: Int,
        x: Double,
        y: Double,
        size: Double,
        tuning: MovementTuning
    ) -> [Edge] {
        touchChanged(
            touch: id, x: x, y: y, size: size,
            deadZoneRatio: tuning.deadZoneRatio,
            cardinalOnlyRadiusRatio: tuning.cardinalOnlyRadiusRatio,
            slideOffMargin: tuning.slideOffMargin
        )
    }

    public mutating func touchEnded(touch id: Int) -> [Edge] {
        guard let index = touches.firstIndex(where: { $0.id == id }) else { return [] }
        touches.remove(at: index)
        return diff(to: union)
    }

    public mutating func releaseAll() -> [Edge] {
        touches.removeAll()
        return diff(to: [])
    }

    private var union: DirectionSet {
        touches.reduce(into: DirectionSet()) { $0.formUnion($1.directions) }
    }

    static func directions(
        x: Double,
        y: Double,
        size: Double,
        deadZoneRatio: Double,
        cardinalOnlyRadiusRatio: Double,
        slideOffMargin: Double
    ) -> DirectionSet {
        let radius = size / 2
        let dx = x - radius
        let dy = y - radius
        let distance = (dx * dx + dy * dy).squareRoot()

        if distance > radius + slideOffMargin {
            return []
        }

        if distance < radius * deadZoneRatio {
            return []
        }

        let angle = atan2(dy, dx)

        // Near the pivot, a small thumb wobble is a large angle. RGSS
        // `Input.dir4` switches to the other held direction, so an
        // accidental diagonal steers a 4-way game sideways.
        if distance < radius * cardinalOnlyRadiusRatio {
            return DirectionSet(cardinalAngle: angle)
        }

        return DirectionSet(angle: angle)
    }

    private mutating func diff(to newSet: DirectionSet) -> [Edge] {
        guard newSet != active else { return [] }
        let released = active.subtracting(newSet).directions
        let pressed = newSet.subtracting(active).directions
        active = newSet
        return released.map { Edge(direction: $0, pressed: false) }
            + pressed.map { Edge(direction: $0, pressed: true) }
    }
}
