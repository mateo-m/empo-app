import Foundation

/// The attach of SPEC 11.11 and 4.3.
///
/// Snapshots that match no installed game sit in the trailing "Other
/// snapshots" section. The attach records an identity alias, so the
/// question is asked once.
///
/// The alias goes in two places: the game's `EmpoState/`, through
/// `IdentityAliases`, and the header of every later manifest. The
/// second place is what a device with no local state reads.
///
/// A device that reads an alias renames nothing.
public enum AttachAction {

    /// The title of the game picker.
    public static let pickTitle = screenText("Restore into a different game")

    /// The row that opens the picker.
    public static let actionLabel = pickTitle + "…"

    public static func pickBody(snapshotName: String) -> String {
        screenText("Pick the game this backup of %@ restores into.", snapshotName)
    }

    public static func confirmTitle(targetGameName: String) -> String {
        screenText("Restore into %@?", targetGameName)
    }

    public static func confirmBody(targetGameName: String) -> String {
        screenText("This backup will fill %@'s saves and settings. Future backups of "
            + "%@ will match this backup automatically.", targetGameName, targetGameName)
    }

    public static let cancelLabel = screenText("Cancel")

    public static func failedTitle(targetGameName: String) -> String {
        screenText("Couldn't link this backup to %@", targetGameName)
    }

    public static let failedBody = screenText("Nothing was restored.")
    public static let failedDismissLabel = screenText("OK")

    public static func confirmLabel(targetGameName: String) -> String {
        screenText("Restore into %@", targetGameName)
    }

    /// Records the attach in the game's alias store.
    ///
    /// Answers the store to write, or `nil` where the game already
    /// answers to the snapshot's name and nothing changes. A second
    /// attach of the same snapshot therefore writes nothing and asks
    /// no second question.
    public static func record(
        snapshot: SnapshotIdentity, into game: GameIdentity, aliases: IdentityAliases
    ) -> IdentityAliases? {
        guard let alias = GameIdentityMatch.alias(attaching: snapshot, to: game) else {
            return nil
        }
        var updated = aliases
        guard updated.add(alias, forFolderName: game.folderName) else { return nil }
        return updated
    }
}
