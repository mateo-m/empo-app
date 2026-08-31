import Foundation

/// One destructive confirmation of SPEC 13.15.
public struct LeftoverConfirmation: Equatable, Sendable {

    public var title: String
    public var body: String
    public var buttonLabel: String

    public init(title: String, body: String, buttonLabel: String) {
        self.title = title
        self.body = body
        self.buttonLabel = buttonLabel
    }
}

/// The "Left over from a restore" section of SPEC 13.15 and 11.12.
///
/// One row for the replaced tree with its size, and one row for the
/// displaced copies with a count and a total. Each deletes behind a
/// confirmation that names what goes. There is no "Delete all",
/// because this is data the player may still want.
public enum RestoreLeftovers {

    public static let heading = "Left over from a restore"

    /// `sizeText` carries the size in the words the caller
    /// formatted.
    public static func replacedTreeRow(sizeText: String) -> String {
        "Replaced game files, \(sizeText)"
    }

    public static func displacedCopiesRow(count: Int, sizeText: String) -> String {
        let copies = count == 1 ? "1 replaced file" : "\(count) replaced files"
        return "\(copies), \(sizeText)"
    }

    public static func replacedTreeConfirmation(
        gameName: String, sizeText: String
    ) -> LeftoverConfirmation {
        LeftoverConfirmation(
            title: "Delete the replaced game files?",
            body:
                "A restore moved these files aside. They hold \(sizeText) of the game files "
                + "\(gameName) had before that restore.",
            buttonLabel: "Delete")
    }

    public static func displacedCopiesConfirmation(
        count: Int, sizeText: String
    ) -> LeftoverConfirmation {
        let copies = count == 1 ? "1 file" : "\(count) files"
        return LeftoverConfirmation(
            title: count == 1 ? "Delete 1 replaced file?" : "Delete \(count) replaced files?",
            body:
                "A restore moved \(copies) aside and wrote the backup's files in their place. "
                + "The moved files hold \(sizeText).",
            buttonLabel: count == 1 ? "Delete 1 file" : "Delete \(count) files")
    }

    /// The one warning of 11.12. Empo warns once when a single file
    /// passes three copies, because dropping the oldest copy by
    /// itself would be a silent delete of user data.
    public static func copyWarning(fileName: String, count: Int) -> String? {
        guard count > DisplacedCopy.copyWarningCount else { return nil }
        return "\(fileName) now has \(count) replaced copies on this device."
    }
}
