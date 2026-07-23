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

    public init(dpad: DPadSpec? = nil, buttons: [ButtonSpec]? = nil) {
        self.dpad = dpad
        self.buttons = buttons
    }
}

public struct DPadSpec: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var size: Double?
    public var opacity: Double?

    public init(x: Double, y: Double, size: Double? = nil, opacity: Double? = nil) {
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
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
