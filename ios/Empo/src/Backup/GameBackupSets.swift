import Foundation
import GameProbe

@MainActor
enum GameBackupSets {

    // MARK: - The set

    static func request(
        for container: GameContainer, mode: BackupMode
    ) async throws -> GameBackupSetRequest {
        let manualMarks: [String]
        do {
            manualMarks = try GameBackupIntent.load(from: container.empoStateURL).manualMarks
        } catch  where mode == .full {
            // The full set holds each file, so it needs no marks.
            manualMarks = []
        }
        var buckets: [String: URL] = [:]
        for bucket in RescuedSaves.matchingBuckets(
            in: DataDirectory.rescuedSavesRootURL, folderName: container.folderName)
        {
            buckets[bucket.lastPathComponent] = bucket
        }

        return GameBackupSetRequest(
            containerURL: container.url,
            mode: mode,
            sharedDataDirectory: DataDirectory.resolve(
                for: container, core: GameCores.core(forGameAt: container.gameURL)),
            documentsRoot: DataDirectory.documentsRootURL,
            rescuedSavesBuckets: buckets,
            manualMarks: manualMarks,
            runtimeWatchPaths: await GameSaveWatch.shared.joinedPaths(forGame: container.id))
    }

    static func libraryRequest(userDefaultsExportFile: URL?) -> LibraryBackupSetRequest {
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

    /// The tree size uses the same enumerator `GameMetadata.diskSize`
    /// uses, so the number the ask shows is the number the library
    /// card shows.
    static func resolveMode(
        for container: GameContainer, targets: [BackupTargetThreshold]
    ) async throws -> BackupModeResolution {
        let intent: GameBackupIntent
        do {
            intent = try GameBackupIntent.load(from: container.empoStateURL)
        } catch is DecodingError {
            // The rule picks full or the ask for a game with no mode, never
            // slim, so the marks of the damaged file are not needed.
            BackupLog.line(
                "GameBackupSets",
                "\(container.folderName) backup settings are damaged, so the mode is asked again")
            intent = GameBackupIntent()
        }
        if let answered = intent.mode { return .mode(answered) }
        let treeSize = await GameMetadata.diskSize(for: container.gameURL)
        return BackupThreshold.resolveMode(
            intent: intent, gameTreeBytes: treeSize, targets: targets)
    }

    /// Answers whether the game became dirty, per 3.9. The caller marks
    /// the game dirty in `state.sqlite`.
    ///
    /// A damaged `backup.json` moves aside and the mode goes into a new
    /// file, so the ask of 3.5 does not come back at each run.
    @discardableResult
    static func setMode(_ mode: BackupMode, for container: GameContainer) throws -> Bool {
        let stateURL = container.empoStateURL
        let intent: GameBackupIntent
        do {
            intent = try GameBackupIntent.load(from: stateURL)
        } catch is DecodingError {
            try BackupRoot.setAside(stateURL.appendingPathComponent(GameBackupIntent.fileName))
            intent = GameBackupIntent()
        }
        let dirty = BackupModeChange.makesDirty(from: intent.mode, to: mode)
        try BackupModeChange.apply(mode, to: intent).save(to: stateURL)
        return dirty
    }
}
