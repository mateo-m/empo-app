import Foundation

/// One Empo action a control can trigger instead of a game key.
public struct EmpoAction: Equatable, Sendable {
    public enum Kind: Sendable {
        /// Active while the control is held.
        case hold
        /// Flips on or off per press.
        case toggle
        /// Fires once per press.
        case instant
    }

    /// Closed `$`-prefixed identifier. This is the file vocabulary.
    public let id: String
    /// Human-readable name for pickers, the remap screen, and docs.
    public let displayName: String
    /// One-line description for pickers and docs.
    public let blurb: String
    /// SF Symbol name. Plain string so this table stays Linux-buildable.
    public let symbolName: String
    public let kind: Kind
    /// Whether `actionButtons` may reference this action. Controller
    /// maps may reference every action.
    public let touchValid: Bool

    public init(
        id: String,
        displayName: String,
        blurb: String,
        symbolName: String,
        kind: Kind,
        touchValid: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.blurb = blurb
        self.symbolName = symbolName
        self.kind = kind
        self.touchValid = touchValid
    }
}

/// The closed action vocabulary. Loader validation, the app registry,
/// and the docs all read this one table.
public enum EmpoActionCatalog {
    public static let fastForwardHold = "$fastForward"
    public static let fastForwardToggle = "$toggleFastForward"
    public static let pauseMenu = "$pauseMenu"
    public static let toggleCheats = "$toggleCheats"
    public static let toggleTouchControls = "$toggleTouchControls"

    public static let all: [EmpoAction] = [
        EmpoAction(
            id: fastForwardHold,
            displayName: "Fast forward (hold)",
            blurb: "Speeds the game up while you hold the button.",
            symbolName: "forward.fill",
            kind: .hold,
            touchValid: true
        ),
        EmpoAction(
            id: fastForwardToggle,
            displayName: "Fast forward",
            blurb: "Turns fast forward on or off.",
            symbolName: "forward.circle",
            kind: .toggle,
            touchValid: true
        ),
        EmpoAction(
            id: pauseMenu,
            displayName: "Pause menu",
            blurb: "Opens the pause menu.",
            symbolName: "pause.circle",
            kind: .instant,
            touchValid: true
        ),
        EmpoAction(
            id: toggleCheats,
            displayName: "Cheats",
            blurb: "Turns the cheats screen on or off.",
            symbolName: "wand.and.stars",
            kind: .toggle,
            touchValid: true
        ),
        EmpoAction(
            id: toggleTouchControls,
            displayName: "Show/hide touch controls",
            blurb: "Shows or hides the on-screen controls.",
            symbolName: "hand.tap",
            kind: .instant,
            touchValid: false
        ),
    ]

    public static let allIDs: Set<String> = Set(all.map(\.id))
    public static let touchIDs: Set<String> = Set(all.filter(\.touchValid).map(\.id))

    public static func action(id: String) -> EmpoAction? {
        all.first { $0.id == id }
    }

    /// Renamed action ids from before this vocabulary existed. The
    /// parser never consults this. Callers that own a stored map run
    /// `migrated(_:)` once and save the result.
    public static let renamedIDs: [String: String] = [
        "$toggleOverlay": toggleTouchControls
    ]

    /// Rewrites renamed action ids in a stored controller map.
    /// Idempotent: after one pass no old id remains.
    public static func migrated(_ map: ControllerMap) -> (map: ControllerMap, changed: Bool) {
        var result = map
        var changed = false
        for (element, target) in map.entries {
            if case .action(let name) = target, let newName = renamedIDs[name] {
                result.entries[element] = .action(newName)
                changed = true
            }
        }
        return (result, changed)
    }
}
