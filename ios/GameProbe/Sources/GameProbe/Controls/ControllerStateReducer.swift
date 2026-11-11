// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum ControllerDigitalThreshold {
    public static let press: Float = 0.5
    public static let release: Float = 0.4

    public static func axisPressed(value: Float, wasPressed: Bool) -> Bool {
        let magnitude = abs(value)
        if wasPressed {
            return magnitude >= release
        }
        return magnitude >= press
    }

    public static func buttonPressed(value: Float) -> Bool {
        value >= press
    }
}

public struct ControllerStateReducer: Sendable {
    public struct Edge: Equatable, Sendable {
        public let element: String
        public let pressed: Bool

        public init(element: String, pressed: Bool) {
            self.element = element
            self.pressed = pressed
        }
    }

    private var perController: [String: [String: Bool]] = [:]
    private var merged: [String: Bool] = [:]

    public init() {}

    public mutating func apply(
        controllerID: String,
        element: String,
        value: Float,
        isAxis: Bool
    ) -> [Edge] {
        var controllerState = perController[controllerID] ?? [:]
        let prior = controllerState[element] ?? false
        let digital = isAxis
            ? ControllerDigitalThreshold.axisPressed(value: value, wasPressed: prior)
            : ControllerDigitalThreshold.buttonPressed(value: value)
        controllerState[element] = digital
        perController[controllerID] = controllerState
        return reconcileMerged(element: element)
    }

    public mutating func removeController(_ controllerID: String) -> [Edge] {
        guard perController.removeValue(forKey: controllerID) != nil else { return [] }
        return reconcileAllMerged()
    }

    public var mergedPressedElements: [String] {
        merged.filter(\.value).map(\.key).sorted()
    }

    private mutating func reconcileMerged(element: String) -> [Edge] {
        let oldMerged = merged[element] ?? false
        let newMerged = Self.mergedPressed(for: element, perController: perController)
        merged[element] = newMerged
        guard newMerged != oldMerged else { return [] }
        return [Edge(element: element, pressed: newMerged)]
    }

    private mutating func reconcileAllMerged() -> [Edge] {
        let elements = Set(perController.values.flatMap(\.keys)).union(merged.keys)
        var edges: [Edge] = []
        for element in elements.sorted() {
            edges.append(contentsOf: reconcileMerged(element: element))
        }
        return edges
    }

    private static func mergedPressed(
        for element: String,
        perController: [String: [String: Bool]]
    ) -> Bool {
        for state in perController.values {
            if state[element] == true {
                return true
            }
        }
        return false
    }
}

/// GCController Y is positive up. SDL `-lefty` is stick up.
public enum ControllerStickMapper {
    public struct Sample: Equatable, Sendable {
        public let element: String
        public let value: Float
        public let isAxis: Bool

        public init(element: String, value: Float, isAxis: Bool = true) {
            self.element = element
            self.value = value
            self.isAxis = isAxis
        }
    }

    /// A push within this angle of an axis is that axis alone. A
    /// thumb that pushes "right" drifts 10 to 20 degrees off the
    /// axis, so 30 keeps it on one direction. Diagonals keep the
    /// 30 degrees in the middle of each quadrant.
    public static let cardinalHalfWidthDegrees: Float = 30

    /// A sector boundary moves this far away from the held sector, so
    /// a thumb that rests on a boundary does not flicker between
    /// one direction and two.
    public static let sectorMarginDegrees: Float = 5

    /// The engine resolves two held directions in `updateDir4`
    /// (`src/input/input.cpp`): it keeps the direction held first,
    /// otherwise it takes the first of down, left, right, up. When the
    /// two half-axes of one push crossed their thresholds at different
    /// times, the in-game direction depended on that order. An Xbox
    /// Wireless Controller left stick then walked in a direction that
    /// changed from push to push. A sector emits both edges of a
    /// diagonal in one sample, so the order is fixed.
    public static func directions(x: Float, y: Float, held: Set<ControlDirection>) -> Set<ControlDirection> {
        let magnitude = (x * x + y * y).squareRoot()
        if magnitude < ControllerDigitalThreshold.release {
            return []
        }
        let angle = atan2(y, x) * 180 / .pi
        let horizontal: ControlDirection = x >= 0 ? .right : .left
        let vertical: ControlDirection = y >= 0 ? .up : .down
        let offsetFromHorizontal = min(abs(angle), 180 - abs(angle))
        let offsetFromVertical = 90 - offsetFromHorizontal
        let nearestCardinal = offsetFromHorizontal <= offsetFromVertical ? horizontal : vertical
        let offset = min(offsetFromHorizontal, offsetFromVertical)
        let diagonal: Set<ControlDirection> = [horizontal, vertical]

        var boundary = cardinalHalfWidthDegrees
        if held == [nearestCardinal] {
            boundary += sectorMarginDegrees
        } else if held == diagonal {
            boundary -= sectorMarginDegrees
        }
        return offset <= boundary ? [nearestCardinal] : diagonal
    }

    public static func halfAxisSamples(stick: String, x: Float, y: Float, active: Set<ControlDirection>) -> [Sample] {
        let magnitude = min(1, (x * x + y * y).squareRoot())
        return ControlDirection.allCases.map { direction in
            Sample(
                element: ControllerElement.halfAxis(stick: stick, direction: direction),
                value: active.contains(direction) ? magnitude : 0
            )
        }
    }
}
