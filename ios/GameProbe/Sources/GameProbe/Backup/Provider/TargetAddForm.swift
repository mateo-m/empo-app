import Foundation

/// One field of the add form of SPEC 13.7.
///
/// The form belongs to ticket 016. The fields belong to the provider
/// ticket, because only it knows what its service needs. This type
/// is what the two agree on.
public struct TargetFormField: Equatable, Sendable {

    /// What the field holds.
    public enum Kind: Equatable, Sendable {
        /// One line of text.
        case text
        /// One line the screen hides and the Keychain keeps, per 6.7.
        case secret
        /// On or off.
        case toggle
    }

    /// The name the form reads the value back by.
    public let name: String
    /// What the screen shows above the field.
    public let label: String
    /// The example the field shows while it is empty.
    public let hint: String
    public let kind: Kind
    /// Whether the add button waits for this field.
    public let isRequired: Bool
    /// The line beside the field, per 13.7. Only the host field of a
    /// service the user hosts carries one.
    public let note: String?

    public init(
        name: String,
        label: String,
        hint: String = "",
        kind: Kind = .text,
        isRequired: Bool = true,
        note: String? = nil
    ) {
        self.name = name
        self.label = label
        self.hint = hint
        self.kind = kind
        self.isRequired = isRequired
        self.note = note
    }
}
