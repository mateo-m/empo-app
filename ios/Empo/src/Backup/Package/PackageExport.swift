import Foundation
import GameProbe
import UIKit

/// What this device puts in a package, per SPEC 12.4.
enum PackageExport {

    /// The plan for one game. It uses that game's current mode.
    @MainActor
    static func plan(game container: GameContainer) async -> PackagePlan {
        let name = BackupGameNames.name(of: container)
        return PackagePlan(gameName: name, streams: [await stream(of: container, gameName: name)])
    }

    /// The plan for the whole library: each game at its current
    /// mode, plus the preferences stream, the layout profiles, and
    /// the Rescued Saves tree.
    @MainActor
    static func libraryPlan() async -> PackagePlan {
        var streams: [PackagePlan.Stream] = []
        for container in GameContainer.discover() {
            streams.append(await stream(of: container, gameName: BackupGameNames.name(of: container)))
        }
        if let preferences = preferencesStream() { streams.append(preferences) }
        return PackagePlan(gameName: nil, streams: streams)
    }

    @MainActor
    private static func stream(
        of container: GameContainer, gameName: String
    ) async -> PackagePlan.Stream {
        let mode = await self.mode(of: container)
        let request = await GameBackupSets.request(for: container, mode: mode)
        let set = BackupSetResolver.resolve(request)
        let identity = GameIdentities.identity(for: container)
        return PackagePlan.Stream(
            key: identity.gameKey,
            gameName: gameName,
            mode: set.mode,
            containerFolderName: container.folderName,
            identityAlias: identity.aliases.last,
            versionMarker: GameIdentities.versionMarker(for: container),
            sharedDataDirectory: set.sharedDataDirectory,
            rescuedSavesBuckets: set.rescuedSavesBuckets,
            members: set.members,
            source: MemberSource(game: request))
    }

    /// The stream that belongs to no game, per 5.3, with the
    /// UserDefaults export of 10.1 written into staging first.
    @MainActor
    private static func preferencesStream() -> PackagePlan.Stream? {
        guard let file = DevicePreferences.writeTheExportFile() else { return nil }
        let request = GameBackupSets.libraryRequest(userDefaultsExportFile: file)
        let set = BackupSetResolver.resolveLibraryStream(request)
        guard !set.members.isEmpty else { return nil }
        return PackagePlan.Stream(
            key: BackupStream.preferencesKey,
            gameName: nil,
            mode: set.mode,
            containerFolderName: "",
            versionMarker: SnapshotManifest.VersionMarker(),
            rescuedSavesBuckets: set.rescuedSavesBuckets,
            members: set.members,
            source: MemberSource(library: request))
    }

    @MainActor
    private static func mode(of container: GameContainer) async -> BackupMode {
        let resolution = await GameBackupSets.resolveMode(
            for: container, targets: BackupTargets.thresholds())
        // A game that never answered the ask of 3.5 exports its save
        // members, which is what the ask's own default is.
        guard case .mode(let mode) = resolution else { return .slim }
        return mode
    }
}
