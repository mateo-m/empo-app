import Foundation

/// One of the two actions the refusal of SPEC 13.10 offers.
public enum TargetRemovalRefusalAction: String, Equatable, Sendable {
    case removeWithoutDeleting
    case cancel

    public var label: String {
        switch self {
        case .removeWithoutDeleting: return "Remove without deleting"
        case .cancel: return "Cancel"
        }
    }
}

/// Why Empo will not delete the backups now, and what it offers
/// instead.
public struct TargetRemovalRefusal: Equatable, Sendable {

    public var line: String
    /// Exactly two, per 13.10.
    public var actions: [TargetRemovalRefusalAction]

    public init(line: String, actions: [TargetRemovalRefusalAction]) {
        self.line = line
        self.actions = actions
    }
}

/// What the confirm button does, per SPEC 13.10.
public enum TargetRemovalAnswer: Equatable, Sendable {
    /// Remove the target here. The backups stay on the service.
    case remove
    /// Remove the target here and delete this device's namespace.
    case removeAndDelete
    case refuse(TargetRemovalRefusal)
}

/// The remove sheet of SPEC 13.10.
public struct TargetRemovalSheet: Equatable, Sendable {

    public var title: String
    public var body: String
    /// The one unchecked row.
    public var deleteLabel: String
    /// "Remove" or "Remove and delete", to match the box.
    public var confirmLabel: String

    public init(title: String, body: String, deleteLabel: String, confirmLabel: String) {
        self.title = title
        self.body = body
        self.deleteLabel = deleteLabel
        self.confirmLabel = confirmLabel
    }
}

/// The remove rules of SPEC 13.10.
///
/// Removing is local-only, per 8.8. It changes nothing on another
/// device, and a checked box deletes this device's namespace only,
/// per the scope rule of 5.13.
public enum TargetRemovalRules {

    public static func sheet(
        target: TargetDescriptor, deleteBackups: Bool, deviceName: String = "this device"
    ) -> TargetRemovalSheet {
        let name = target.displayName
        return TargetRemovalSheet(
            title: "Remove \(name)?",
            body: """
                Empo stops backing up to \(name). \
                The backups already there stay in your account.
                """,
            deleteLabel: "Also delete \(deviceName)'s backups on \(name)",
            confirmLabel: deleteBackups ? "Remove and delete" : "Remove")
    }

    /// What the confirm button does.
    ///
    /// Empo refuses a checked box on an unreachable target.
    /// Removing anyway would tell the user their data is gone when
    /// it is not. Queueing the deletion would keep a Keychain secret
    /// for a target the user just removed.
    public static func answer(
        deleteBackups: Bool, state: TargetRowState, target: TargetDescriptor
    ) -> TargetRemovalAnswer {
        guard deleteBackups else { return .remove }
        guard case .unreachable = state else { return .removeAndDelete }
        return .refuse(
            TargetRemovalRefusal(
                line: "Empo cannot delete the backups while \(target.displayName) is unreachable.",
                actions: [.removeWithoutDeleting, .cancel]))
    }
}
