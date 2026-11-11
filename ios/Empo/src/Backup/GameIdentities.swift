import Foundation
import GameProbe

/// The app-side half of SPEC 4: it hands the pure rules the paths and
/// the metadata only the app knows.
///
/// The ladder, the alias store, and the marker live in
/// `GameIdentityMatch`, `IdentityAliases`, and `VersionMarkerBuilder`,
/// inside GameProbe, where `swift test` reaches them.
@MainActor
enum GameIdentities {

    // MARK: - Identity, per 4.1 and 4.3

    /// The identity of one game: the container folder name, plus
    /// every alias an earlier attach recorded.
    static func identity(for container: GameContainer) -> GameIdentity {
        ((try? IdentityAliases.load(from: container.empoStateURL)) ?? IdentityAliases())
            .identity(forFolderName: container.folderName)
    }

    static func installedIdentities() -> [GameIdentity] {
        GameContainer.discover().map(identity(for:))
    }

    // MARK: - Matching, per 4.2

    /// The installed game a snapshot belongs to, or `nil` when
    /// nothing matches. A snapshot that matches nothing waits for the
    /// attach of 4.3, and the picker of 11.11 offers it.
    static func match(_ snapshot: SnapshotIdentity) -> GameContainer? {
        let containers = GameContainer.discover()
        let identities = containers.map(identity(for:))
        guard let matched = GameIdentityMatch.match(snapshot, among: identities) else {
            return nil
        }
        return containers.first { $0.folderName == matched.folderName }
    }

    // MARK: - The attach, per 4.3

    /// Records the snapshot's old folder name as an alias of
    /// `container`, in the game's `EmpoState/`. Answers whether the
    /// store changed.
    @discardableResult
    static func attach(
        _ snapshot: SnapshotIdentity, to container: GameContainer
    ) throws -> Bool {
        guard
            let updated = AttachAction.record(
                snapshot: snapshot, into: identity(for: container),
                aliases: try IdentityAliases.load(from: container.empoStateURL))
        else { return false }
        try updated.save(to: container.empoStateURL)
        return true
    }

    // MARK: - The version marker, per 4.4

    /// The marker of the game's tree. The JGP `manifestVersion`
    /// comes from `Metadata/metadata.json`, and it is `nil` for every
    /// import that was not a JoiPlay archive.
    static func versionMarker(for container: GameContainer) -> SnapshotManifest.VersionMarker {
        VersionMarkerBuilder.make(
            gameDirectory: container.gameURL,
            jgpManifestVersion: GameMetadata.load(from: container).manifestVersion)
    }
}
