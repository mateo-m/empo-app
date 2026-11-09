// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public struct ControlsManifest: Equatable, Sendable {
    public var version: Int
    public var touch: TouchSection?
    public var bindings: BindingMap?

    public init(
        version: Int,
        touch: TouchSection? = nil,
        bindings: BindingMap? = nil
    ) {
        self.version = version
        self.touch = touch
        self.bindings = bindings
    }
}

public struct TouchSection: Equatable, Sendable {
    public var portrait: TouchLayout?
    public var landscape: TouchLayout?

    public init(portrait: TouchLayout? = nil, landscape: TouchLayout? = nil) {
        self.portrait = portrait
        self.landscape = landscape
    }
}

public struct TouchLayout: Equatable, Sendable {
    public var dpad: DPadSpec?
    public var buttons: [ButtonSpec]?
    public var actionButtons: [ActionButtonSpec]?

    public init(
        dpad: DPadSpec? = nil,
        buttons: [ButtonSpec]? = nil,
        actionButtons: [ActionButtonSpec]? = nil
    ) {
        self.dpad = dpad
        self.buttons = buttons
        self.actionButtons = actionButtons
    }
}

/// The file key stays `dpad` for both styles. Both styles use the same
/// key mapping and direction math.
public enum MovementStyle: String, Equatable, Sendable, CaseIterable, Codable {
    case dpad
    case stick
}

public struct DPadSpec: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var size: Double?
    public var opacity: Double?
    /// An absent file field means `.dpad`, and the serializer omits the
    /// field for `.dpad`.
    public var style: MovementStyle

    public init(
        x: Double,
        y: Double,
        size: Double? = nil,
        opacity: Double? = nil,
        style: MovementStyle = .dpad
    ) {
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
        self.style = style
    }
}

public struct ButtonSpec: Equatable, Sendable {
    public var label: String?
    public var key: String
    public var x: Double
    public var y: Double
    public var size: Double?
    public var opacity: Double?

    public init(
        label: String? = nil,
        key: String,
        x: Double,
        y: Double,
        size: Double? = nil,
        opacity: Double? = nil
    ) {
        self.label = label
        self.key = key
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
    }
}

/// This button has no label. The renderer shows the fixed icon of the
/// action.
public struct ActionButtonSpec: Equatable, Sendable {
    public var action: String
    public var x: Double
    public var y: Double
    public var size: Double?
    public var opacity: Double?

    public init(
        action: String,
        x: Double,
        y: Double,
        size: Double? = nil,
        opacity: Double? = nil
    ) {
        self.action = action
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
    }
}

/// A controller in keyboard mode sends keys. `"KeyJ": "a"` puts that
/// key under the A button, so every A binding applies to it: the Empo
/// default, the manifest of the game, and the player's own.
public enum ControlsTarget: Equatable, Sendable {
    case key(String)
    case element(String)
    case action(String)
    case unbound
}

/// The element names and the key names are disjoint, and a test
/// enforces it. Thus one name always gives one kind.
public enum BindingSource: Hashable, Sendable {
    case element(String)
    case key(String)

    public init?(name: String) {
        if ControllerElement.allNames.contains(name) {
            self = .element(name)
        } else if KeyCodeTable.scancode(for: name) != nil {
            self = .key(name)
        } else {
            return nil
        }
    }

    public var name: String {
        switch self {
        case .element(let name), .key(let name): return name
        }
    }

    public var isElement: Bool {
        if case .element = self { return true }
        return false
    }
}

public struct BindingMap: Equatable, Sendable {
    public typealias Target = ControlsTarget

    public var entries: [BindingSource: Target]

    public init(entries: [BindingSource: Target] = [:]) {
        self.entries = entries
    }

    public var elementEntries: [String: Target] {
        var out: [String: Target] = [:]
        for (source, target) in entries {
            if case .element(let name) = source { out[name] = target }
        }
        return out
    }

    public var keyEntries: [String: Target] {
        var out: [String: Target] = [:]
        for (source, target) in entries {
            if case .key(let name) = source { out[name] = target }
        }
        return out
    }
}

public enum ControllerElement {
    public static let allNames: Set<String> = Set(allElements)

    public static let allElements: [String] = [
        "a", "b", "x", "y",
        "back", "guide", "start",
        "leftstick", "rightstick",
        "leftshoulder", "rightshoulder",
        "dpup", "dpdown", "dpleft", "dpright",
        "paddle1", "paddle2", "paddle3", "paddle4",
        "touchpad",
        "lefttrigger", "righttrigger",
    ]
        + ["left", "right"].flatMap { stick in
            [ControlDirection.left, .right, .up, .down].map { halfAxis(stick: stick, direction: $0) }
        }

    /// SDL names a stick direction by the sign and the axis: `-lefty`
    /// is the left stick pushed up.
    public static func halfAxis(stick: String, direction: ControlDirection) -> String {
        switch direction {
        case .up: "-\(stick)y"
        case .down: "+\(stick)y"
        case .left: "-\(stick)x"
        case .right: "+\(stick)x"
        }
    }
}
