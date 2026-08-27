import Foundation

/// What identifies one installed game, per SPEC 4.1 and 4.3.
///
/// The container folder name is the identity. Empo assigns no
/// separate id, no UUID, and no content fingerprint. The name is
/// unique per device by construction, and it is frozen at import: a
/// self-update that rewrites the INI title does not rename the
/// container.
///
/// An attach adds the old folder name as an alias, per 4.3. A game
/// carries every alias it collected, and each one matches for it.
public struct GameIdentity: Equatable, Sendable {

    /// `Documents/Games/<folderName>/`, the sanitized INI title.
    public var folderName: String

    /// The names earlier attaches recorded, per 4.3, oldest first.
    public var aliases: [String]

    public init(folderName: String, aliases: [String] = []) {
        self.folderName = folderName
        self.aliases = aliases
    }

    /// Every name this game answers to: the folder name first, then
    /// the aliases.
    public var names: [String] {
        [folderName] + aliases
    }

    /// The key of the game's folder under `games/`, per 5.2. The
    /// alias never makes a key, so an attach moves no snapshot.
    public var gameKey: String {
        BackupKeys.gameKey(containerFolderName: folderName)
    }
}

/// What identifies the game a snapshot came from, per 5.5.
///
/// A device with no local state reads this out of the manifest
/// header. That is the case the alias exists for, per 4.3.
public struct SnapshotIdentity: Equatable, Sendable {

    /// The exact container folder name the manifest carries.
    public var containerFolderName: String

    /// The alias the manifest carries, when the game has one.
    public var identityAlias: String?

    public init(containerFolderName: String, identityAlias: String? = nil) {
        self.containerFolderName = containerFolderName
        self.identityAlias = identityAlias
    }

    public init(manifest: SnapshotManifest) {
        self.init(
            containerFolderName: manifest.containerFolderName,
            identityAlias: manifest.identityAlias)
    }

    /// Every name this snapshot answers to.
    public var names: [String] {
        guard let identityAlias else { return [containerFolderName] }
        return [containerFolderName, identityAlias]
    }

    public var gameKey: String {
        BackupKeys.gameKey(containerFolderName: containerFolderName)
    }
}
