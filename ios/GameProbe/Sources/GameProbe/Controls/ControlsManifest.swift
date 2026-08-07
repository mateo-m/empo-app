import Foundation

public struct ControlsManifest: Equatable, Sendable {
    public var version: Int
    public var touch: TouchSection?
    public var controller: ControllerMap?

    public init(
        version: Int,
        touch: TouchSection? = nil,
        controller: ControllerMap? = nil
    ) {
        self.version = version
        self.touch = touch
        self.controller = controller
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

/// Visual style of the single movement control. The file key stays
/// `dpad` for both; `style` picks the renderer. Same key mapping and
/// direction math either way.
public enum MovementStyle: String, Equatable, Sendable, CaseIterable, Codable {
    case dpad
    case stick
}

public struct DPadSpec: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var size: Double?
    public var opacity: Double?
    /// Never optional: an absent file field IS the d-pad, and the
    /// serializer omits the field for `.dpad`, so no consumer ever
    /// needs to tell nil from `.dpad`.
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

/// A touch button bound to an Empo action instead of a game key.
/// It has no label: rendering uses the action's fixed icon.
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

/// Ordered element -> target map. A target is a key, an action, or an
/// explicit unbind.
public struct ControllerMap: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case key(String)
        case action(String)
        case unbound
    }

    public var entries: [String: Target]

    public init(entries: [String: Target] = [:]) {
        self.entries = entries
    }
}

/// Closed SDL controller element vocabulary (SPEC section 7).
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
        "-leftx", "+leftx", "-lefty", "+lefty",
        "-rightx", "+rightx", "-righty", "+righty",
    ]
}
