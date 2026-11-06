import Foundation
import GameProbe

/// The name a game carries on the backup screens.
///
/// One value reads the library once. A screen that names many rows
/// makes one value and asks it for every row, so it walks the
/// containers one time.
@MainActor
struct BackupGameNames {

    /// What the stream that belongs to no game is called, per 5.3.
    static let preferencesName = String(localized: "your settings")

    private let containers: [GameContainer]
    private let identities: [GameIdentity]
    private let remembered: [String: String]

    init() {
        containers = GameContainer.discover()
        identities = containers.map(GameIdentities.identity(for:))
        remembered = Self.readRemembered()
    }

    /// Keeps the names of the games a run backs up, so a location
    /// still names a game after it leaves the library.
    static func remember(_ names: [String: String]) {
        guard !names.isEmpty else { return }
        let merged = readRemembered().merging(names) { _, new in new }
        guard merged != readRemembered(), let data = try? JSONEncoder().encode(merged) else { return }
        try? data.write(to: rememberedURL, options: .atomic)
    }

    private static var rememberedURL: URL {
        BackupRoot.layout.applicationSupport.appendingPathComponent("backup-game-names.json")
    }

    private static func readRemembered() -> [String: String] {
        guard let data = try? Data(contentsOf: rememberedURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// The name of the game a snapshot came from.
    ///
    /// A snapshot that matches no installed game keeps the folder
    /// name its manifest carries, per 11.11.
    func name(of snapshot: SnapshotIdentity) -> String {
        if snapshot.containerFolderName.isEmpty { return Self.preferencesName }
        guard let matched = GameIdentityMatch.match(snapshot, among: identities) else {
            return snapshot.containerFolderName
        }
        return name(of: matched)
    }

    /// The name of one installed game.
    func name(of game: GameIdentity) -> String {
        guard let container = containers.first(where: { $0.folderName == game.folderName })
        else { return game.folderName }
        return Self.name(of: container)
    }

    /// The name of one game key. A key with no game left answers
    /// "this game".
    func name(ofGameKey key: String?) -> String {
        guard let key else { return Self.preferencesName }
        guard
            let container = containers.first(where: {
                BackupKeys.gameKey(containerFolderName: $0.folderName) == key
            })
        else { return remembered[key] ?? String(localized: "this game") }
        return Self.name(of: container)
    }

    /// The name of every installed game, by game key.
    func namesByGameKey() -> [String: String] {
        var names = remembered
        for container in containers {
            names[BackupKeys.gameKey(containerFolderName: container.folderName)] =
                Self.name(of: container)
        }
        return names
    }

    static func name(of container: GameContainer) -> String {
        name(of: container, in: GameMetadata.load(from: container))
    }

    static func name(of container: GameContainer, in metadata: GameMetadata) -> String {
        metadata.customTitle ?? metadata.baseTitle ?? container.folderName
    }
}
