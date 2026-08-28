import Foundation

/// The version-marker sheet of SPEC 11.10. **This copy is
/// canonical.** Ticket 017 renders it and writes no copy of its own.
///
/// It shows in one case: a full-mode restore over a tree whose
/// version marker of 4.4 differs. A restore of saves and settings
/// only never shows it, because that path carries no version risk.
///
/// The sheet names no version number. The marker compares hashes and
/// counts, so Empo never knows a version number to print, and games
/// carry version schemes of their own that any Empo claim would
/// collide with.
public enum VersionMarkerSheet {

    /// What the user picks, per 11.10.
    public enum Action: String, Codable, Sendable, CaseIterable, Equatable {
        /// Puts back the saves alone and touches nothing else. The
        /// safe first choice.
        case savesAndSettingsOnly = "saves-and-settings-only"
        /// Adds the backup's files beside the local ones. Removes
        /// nothing.
        case keepMyFiles = "keep-my-files"
        /// Moves the local game files aside, then writes the
        /// backup's files in their place.
        case useOnlyThisBackup = "use-only-this-backup"

        public var scope: RestoreScope {
            self == .savesAndSettingsOnly ? .savesAndSettings : .wholeGame
        }

        /// Whether the action replaces the tree, per 11.12. Only one
        /// of the three does.
        public var replacesTheTree: Bool {
            self == .useOnlyThisBackup
        }

        public var label: String {
            switch self {
            case .savesAndSettingsOnly: return "Saves and settings only"
            case .keepMyFiles: return "Keep my files"
            case .useOnlyThisBackup: return "Use only this backup"
            }
        }

        public var detail: String {
            switch self {
            case .savesAndSettingsOnly:
                return "Puts back your saves, settings, and control layouts. Touches nothing else."
            case .keepMyFiles:
                return "Adds this backup's files beside yours. Removes nothing."
            case .useOnlyThisBackup:
                return
                    "Moves the game files here aside, then puts this backup's files in their "
                    + "place. The moved files stay in a folder you can open later."
            }
        }
    }

    public static let title = "Different game files"

    public static func body(gameName: String) -> String {
        "This backup holds different game files than \(gameName) has on this device. Mixing two "
            + "sets of game files can break the game.\n\nWhat should happen to the game files "
            + "already here?"
    }

    /// The order the actions appear in. Saves and settings only is
    /// first, because it is the safe first choice.
    public static let actions: [Action] = [
        .savesAndSettingsOnly, .keepMyFiles, .useOnlyThisBackup,
    ]

    /// Whether the sheet shows before this restore, per 4.4 and
    /// 11.10.
    ///
    /// Both halves of "a full-mode restore" have to hold. The scope
    /// has to be the whole game, and the snapshot has to be a
    /// full-mode one. A slim snapshot carries no game files, so it
    /// can bury nothing and the sheet's three actions would read as
    /// noise.
    public static func shows(
        mode: BackupMode,
        scope: RestoreScope,
        snapshot: SnapshotManifest.VersionMarker,
        local: SnapshotManifest.VersionMarker
    ) -> Bool {
        guard scope == .wholeGame else { return false }
        return VersionMarkerBuilder.warnsBeforeRestore(
            mode: mode, snapshot: snapshot, local: local)
    }
}
