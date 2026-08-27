import Foundation

/// Which installed game a snapshot belongs to, per SPEC 4.2 and 4.3.
///
/// The ladder is `DirectoryNameMatch.preferringExisting`, the one
/// the import path and the shared data directory already use. There
/// is no second ladder: exact, case-insensitive, mojibake rendering,
/// and invisible-character variants, in that order.
///
/// The ladder resolves a match and renames nothing. The manifest
/// keeps the exact name, per 4.2.
public enum GameIdentityMatch {

    /// Whether two folder names name one game.
    ///
    /// The ladder runs in both directions, because one rung is not
    /// symmetric: `legacyMojibakeRendering` turns a corrected title
    /// into the mojibake name of the old decode chain, never the
    /// other way. A snapshot from a device of that era carries the
    /// mojibake name, and the corrected name must find it.
    public static func namesMatch(_ one: String, _ other: String) -> Bool {
        DirectoryNameMatch.preferringExisting(one, among: [other]) == other
            || DirectoryNameMatch.preferringExisting(other, among: [one]) == one
    }

    /// Whether a snapshot belongs to a game. Any name of the
    /// snapshot against any name of the game, per 4.3.
    public static func matches(_ snapshot: SnapshotIdentity, _ game: GameIdentity) -> Bool {
        for snapshotName in snapshot.names {
            for gameName in game.names where namesMatch(snapshotName, gameName) {
                return true
            }
        }
        return false
    }

    /// The installed game a snapshot belongs to, or `nil` when
    /// nothing matches.
    ///
    /// A snapshot that matches nothing is not an error. The picker
    /// still lists it under "Other snapshots", and the user attaches
    /// it by hand, per 4.3 and 11.11.
    ///
    /// Three passes, so one snapshot always picks the same game:
    /// the exact folder name first, then the ladder on folder names,
    /// then the aliases. Each pass reads the games in name order.
    public static func match(
        _ snapshot: SnapshotIdentity, among games: [GameIdentity]
    ) -> GameIdentity? {
        let ordered = games.sorted { $0.folderName < $1.folderName }

        if let exact = ordered.first(where: { $0.folderName == snapshot.containerFolderName }) {
            return exact
        }
        if let ladder = ordered.first(where: { game in
            snapshot.names.contains { namesMatch($0, game.folderName) }
        }) {
            return ladder
        }
        return ordered.first { matches(snapshot, $0) }
    }

    /// The alias an attach records, per 4.3, or `nil` when the game
    /// already answers to the snapshot's name.
    ///
    /// The name recorded is the snapshot's own container folder
    /// name, which is the old name of the game. It goes in two
    /// places: the game's `EmpoState/`, through `IdentityAliases`,
    /// and the header of every later manifest. The second place is
    /// what a device with no local state reads.
    public static func alias(
        attaching snapshot: SnapshotIdentity, to game: GameIdentity
    ) -> String? {
        guard !matches(snapshot, game) else { return nil }
        return snapshot.containerFolderName
    }
}
