import Foundation
import GameProbe

/// The app-side half of SPEC 3: it hands the pure resolver the paths
/// only the app knows.
///
/// The rules live in `BackupSetResolver`, `BackupThreshold`, and
/// `RuntimeWatch`, inside GameProbe, where `swift test` reaches them.
/// This file resolves URLs and nothing else.
@MainActor
enum GameBackupSets {

    // MARK: - The set

    /// The request for one game, with the shared data directory of
    /// 4.5, the matching Rescued Saves buckets, the marks of 3.6,
    /// and the joins this app run saw.
    static func request(
        for container: GameContainer, mode: BackupMode
    ) async -> GameBackupSetRequest {
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        var buckets: [String: URL] = [:]
        for bucket in RescuedSaves.matchingBuckets(
            in: DataDirectory.rescuedSavesRootURL, folderName: container.folderName)
        {
            buckets[bucket.lastPathComponent] = bucket
        }

        return GameBackupSetRequest(
            containerURL: container.url,
            mode: mode,
            sharedDataDirectory: DataDirectory.resolve(for: container),
            documentsRoot: DataDirectory.documentsRootURL,
            rescuedSavesBuckets: buckets,
            manualMarks: intent.manualMarks,
            runtimeWatchPaths: await GameSaveWatch.shared.joinedPaths(forGame: container.id))
    }

    /// The stream that belongs to no game, per 5.3: the layout
    /// profiles, the UserDefaults export, and every Rescued Saves
    /// bucket that matches no installed game.
    ///
    /// Ticket 015 writes the UserDefaults export, so the caller
    /// names the file once it exists.
    static func libraryRequest(userDefaultsExportFile: URL? = nil) -> LibraryBackupSetRequest {
        let installed = GameContainer.discover().map(\.folderName)
        var matched: Set<String> = []
        for folderName in installed {
            for bucket in RescuedSaves.matchingBuckets(
                in: DataDirectory.rescuedSavesRootURL, folderName: folderName)
            {
                matched.insert(bucket.lastPathComponent)
            }
        }

        var buckets: [String: URL] = [:]
        for name in FileManager.default.subdirectoryNames(at: DataDirectory.rescuedSavesRootURL)
        where !matched.contains(name) {
            buckets[name] = DataDirectory.rescuedSavesRootURL
                .appendingPathComponent(name, isDirectory: true)
        }

        return LibraryBackupSetRequest(
            profilesDirectory: LayoutProfilesManager.profilesRootURL,
            userDefaultsExportFile: userDefaultsExportFile,
            rescuedSavesBuckets: buckets)
    }

    // MARK: - The mode

    /// The mode for a game, or the ask of 3.5 that decides it.
    ///
    /// The tree size uses the same enumerator `GameMetadata.diskSize`
    /// uses, so the number the ask shows is the number the library
    /// card shows.
    static func resolveMode(
        for container: GameContainer, targets: [BackupTargetThreshold]
    ) async -> BackupModeResolution {
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        if let answered = intent.mode { return .mode(answered) }
        let treeSize = await GameMetadata.diskSize(for: container.gameURL)
        return BackupThreshold.resolveMode(
            intent: intent, gameTreeBytes: treeSize, targets: targets)
    }

    /// Writes the mode into `EmpoState/backup.json` and answers
    /// whether the game became dirty, per 3.9. The caller marks the
    /// game dirty in `state.sqlite` with
    /// `BackupModeChange.dirtyReason`.
    @discardableResult
    static func setMode(_ mode: BackupMode, for container: GameContainer) throws -> Bool {
        let stateURL = container.empoStateURL
        let intent = GameBackupIntent.load(from: stateURL)
        let dirty = BackupModeChange.makesDirty(from: intent.mode, to: mode)
        try BackupModeChange.apply(mode, to: intent).save(to: stateURL)
        return dirty
    }
}
