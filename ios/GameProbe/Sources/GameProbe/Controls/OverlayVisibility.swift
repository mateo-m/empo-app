import Foundation

/// Whether the touch overlay hides itself, as one rule over the facts
/// of the session (SPEC section 10.4).
///
/// Both physical input paths feed this. Neither decides: two owners
/// writing the same flag with their own policy is how an overlay ends
/// up reappearing mid-game when an unrelated pad disconnects.
public struct OverlayVisibility: Equatable, Sendable {
    /// An extended pad can replace the whole overlay. A basic or micro
    /// pad has too few elements, so it never hides anything.
    public private(set) var hasExtendedController = false

    /// Sticky for the session. iOS coalesces every keyboard into one
    /// device, so Empo cannot tell a pad in keyboard mode from an
    /// iPad Magic Keyboard. Waiting for a key press means an attached
    /// keyboard alone never takes the touch controls away.
    public private(set) var keyboardUsed = false

    /// Set when the player toggles visibility by hand. The rule then
    /// stands aside until the automatic answer changes.
    public private(set) var manualOverride = false

    public init() {}

    /// What the rule says, ignoring any manual override.
    public var automaticallyHidden: Bool {
        hasExtendedController || keyboardUsed
    }

    /// nil means "leave the overlay as the player set it".
    public var hidden: Bool? {
        manualOverride ? nil : automaticallyHidden
    }

    public mutating func noteManualToggle() {
        manualOverride = true
    }

    /// A key press from any hardware keyboard.
    public mutating func noteKeyPress() {
        keyboardUsed = true
    }

    /// An extended pad opening the session's controller set is a new
    /// situation, so it clears a hide the player chose by hand. A
    /// basic pad is not, and must not cancel that choice either.
    public mutating func setExtendedController(_ present: Bool, isFirstController: Bool = false) {
        if present, !hasExtendedController, isFirstController {
            manualOverride = false
        }
        hasExtendedController = present
    }

    /// Every controller left. The player's manual choice goes with
    /// them: the next connect starts the automatic rule again.
    public mutating func noteAllControllersDisconnected() {
        manualOverride = false
        hasExtendedController = false
    }
}
