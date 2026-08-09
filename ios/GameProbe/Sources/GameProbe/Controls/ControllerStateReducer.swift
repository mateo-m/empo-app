import Foundation

/// Hysteresis thresholds for analog triggers and stick half-axes
/// (SPEC section 7).
public enum ControllerDigitalThreshold {
    public static let press: Float = 0.5
    public static let release: Float = 0.4

    /// Digital press state for a trigger or half-axis value.
    public static func axisPressed(value: Float, wasPressed: Bool) -> Bool {
        let magnitude = abs(value)
        if wasPressed {
            return magnitude >= release
        }
        return magnitude >= press
    }

    /// Digital press state for a binary button (`isPressed` as 0 or 1).
    public static func buttonPressed(value: Float) -> Bool {
        value >= press
    }
}

/// Pure controller-input reducer: per-element hysteresis, OR-merge across
/// controllers, and merged-state edge detection. Hardware-independent.
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

    /// Applies a raw element sample for one controller. Returns edges on
    /// the OR-merged logical state only.
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

    /// Drops a disconnected controller and emits any merged release edges.
    public mutating func removeController(_ controllerID: String) -> [Edge] {
        guard perController.removeValue(forKey: controllerID) != nil else { return [] }
        return reconcileAllMerged()
    }

    /// The elements now pressed in the OR-merged view.
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

/// Built-in controller map from SPEC section 9.1 with scancodes
/// resolved once.
public enum ControllerBuiltinMap {
    public typealias ResolvedTarget = BindingResolver.ResolvedTarget
    public typealias Resolved = [String: ResolvedTarget]

    public static func builtinResolved() -> Resolved {
        BindingResolver.resolvedRuntimeMap()
    }
}

/// Maps a GCController stick position into SDL half-axis element samples.
/// GC Y is +up. SDL `-lefty` is stick up (SPEC section 7).
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

    public static func halfAxisSamples(stick: String, x: Float, y: Float) -> [Sample] {
        [
            Sample(element: "-\(stick)x", value: max(0, -x)),
            Sample(element: "+\(stick)x", value: max(0, x)),
            Sample(element: "-\(stick)y", value: max(0, y)),
            Sample(element: "+\(stick)y", value: max(0, -y)),
        ]
    }
}
