import Foundation

/// One field of the add form of SPEC 13.7.
///
/// The form belongs to ticket 016. The fields belong to the provider
/// ticket, because only it knows what its service needs. This type
/// is what the two agree on.
public struct TargetFormField: Equatable, Sendable {

    /// What the field holds. The form picks the keyboard by it.
    public enum Kind: Equatable, Sendable {
        case text
        case address
        case userName
        /// A password the user may keep in their password manager.
        case password
        /// A hidden key that is not a sign-in password, so iOS must
        /// not offer to save it.
        case secret
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
    /// The help line under the field.
    public let note: String?
    /// The heading of the form section the field sits in.
    public let group: String

    public init(
        name: String,
        label: String,
        hint: String = "",
        kind: Kind = .text,
        isRequired: Bool = true,
        note: String? = nil,
        group: String
    ) {
        self.name = name
        self.label = label
        self.hint = hint
        self.kind = kind
        self.isRequired = isRequired
        self.note = note
        self.group = group
    }
}
