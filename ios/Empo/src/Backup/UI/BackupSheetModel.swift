import Foundation
import GameProbe

/// What the Backup sheet of SPEC 13.15 reads and writes for one
/// game.
///
/// The status line comes from `GameBackupStatusRules` and the locks
/// come from `BackupSheetLockRules`, both inside GameProbe. This
/// file reads the files, the targets, and the state store those
/// rules take as inputs.
@MainActor
@Observable
final class BackupSheetModel {

    let container: GameContainer
    let gameName: String

    private(set) var status = GameBackupStatus(state: .notSetUp)
    private(set) var lastSuccessAt: Date?
    private(set) var locks = BackupSheetLocks()
    private(set) var mode: BackupMode?
    /// What each mode would upload for this game, per 5.14.
    private(set) var fullBytes: Int64 = 0
    private(set) var slimBytes: Int64 = 0
    /// What this game holds on every target together.
    private(set) var storedBytes: Int64 = 0
    private(set) var editor = SaveFileEditorModel()
    private(set) var leftovers = GameLeftovers()
    private(set) var hasATarget = false
    /// The oversized writes of 3.6 this game still owes an answer.
    private(set) var pendingAsks: [String] = []

    var gameKey: String { BackupKeys.gameKey(containerFolderName: container.folderName) }

    /// The line the "Backup" value row of 13.15 shows, so the row
    /// and the sheet always say the same thing.
    var line: String {
        status.line(lastSuccessText: lastSuccessAt.map(BackupText.day))
    }

    init(container: GameContainer, gameName: String) {
        self.container = container
        self.gameName = gameName
    }

    // MARK: - Reading

    /// Everything the sheet shows. The sheet reads this once, on
    /// the way in.
    func load() async {
        refresh()
        await readTheFiles()
    }

    /// What a run, a lock, or a target changes. It opens the state
    /// database once and walks no directory.
    func refresh() {
        let descriptors = BackupTargets.load()
        hasATarget = !descriptors.isEmpty
        mode = GameBackupIntent.load(from: container.empoStateURL).mode

        let store = try? BackupStateStore(url: BackupRoot.layout.stateDatabase)
        defer { store?.close() }
        readTheStatus(descriptors, store: store)
        readTheStore(descriptors, store: store)
        locks = BackupSheetLockRules.locks(
            runInFlight: BackupScheduler.shared.runningGameKeys.contains(gameKey),
            openGameName: EngineSessionCoordinator.shared.openGameName)
        pendingAsks = GameSaveWatch.shared.pendingAsks(forGame: container.id)
    }

    /// What a change to the game's own files changes. It resolves
    /// the backup set twice and walks the container, so only a
    /// write that moves a file asks for it.
    func readTheFiles() async {
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        await readTheSizes(intent: intent)
        leftovers = RestoreLeftovers.inside(container.url)
    }

    private func readTheStatus(_ descriptors: [TargetDescriptor], store: BackupStateStore?) {
        let read = GameBackupStatusReader.read(
            gameKey: gameKey,
            lastPlayedAt: GameMetadata.load(from: container).lastPlayed,
            descriptors: descriptors,
            store: store,
            now: Date())
        status = read.status
        lastSuccessAt = read.lastSuccessAt
    }

    /// The two figures the mode picker needs, and the editor rows
    /// beside them. Both modes resolve, because the picker names
    /// both sizes whichever mode the game is in.
    private func readTheSizes(intent: GameBackupIntent) async {
        let full = await resolve(.full)
        let slim = await resolve(.slim)
        fullBytes = full.totalSize
        slimBytes = slim.totalSize
        editor = SaveFileEditorModel.from(slim, manualMarks: intent.manualMarks)
    }

    private func resolve(_ mode: BackupMode) async -> GameBackupSet {
        let request = GameBackupSets.request(for: container, mode: mode)
        return await Task.detached { BackupSetResolver.resolve(request) }.value
    }

    private func readTheStore(_ descriptors: [TargetDescriptor], store: BackupStateStore?) {
        guard let store else { return }
        storedBytes = descriptors.reduce(0) { total, descriptor in
            let rows = (try? store.usage(targetId: descriptor.id)) ?? []
            return total + (rows.first { $0.gameKey == gameKey }?.bytes ?? 0)
        }
    }

    // MARK: - Writing

    /// Answering here satisfies the ask of 3.5, so the sheet never
    /// fires it.
    func setMode(_ mode: BackupMode) async {
        guard (try? GameBackupSets.setMode(mode, for: container)) == true else {
            await load()
            return
        }
        BackupScheduler.shared.markDirty(
            container: container, reason: BackupModeChange.dirtyReason)
        await load()
    }

    func setMarks(_ editor: SaveFileEditorModel) async {
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        try? editor.applied(to: intent).save(to: container.empoStateURL)
        await load()
    }

    /// "Back up now" for one game, per 13.11.
    func backUpNow() {
        BackupScheduler.shared.pressBackUpNow(.game(gameKey: gameKey, gameName: gameName))
    }

    func pause() {
        BackupScheduler.shared.pauseTheRun()
    }

    // MARK: - The oversized write of 3.6

    func answerTheAsk(path: String, joins: Bool) async {
        if joins {
            GameSaveWatch.shared.acceptAsk(path: path, forGame: container.id)
        } else {
            GameSaveWatch.shared.declineAsk(path: path, container: container)
        }
        await load()
    }

    // MARK: - The restore door of 11.3

    /// This game's snapshots on every target and every namespace,
    /// newest first.
    func snapshots() async -> [SnapshotRow] {
        let marker = GameIdentities.versionMarker(for: container)
        var rows: [SnapshotRow] = []
        for descriptor in BackupTargets.load() {
            guard let provider = await BackupTargets.provider(for: descriptor) else { continue }
            let scan = RestoreScan(provider: provider, descriptor: descriptor)
            rows +=
                (try? await scan.rows(of: .game(key: gameKey), localMarker: marker)) ?? []
        }
        return RestorePicker.newestFirst(rows)
    }

    func restore(
        _ row: SnapshotRow, scope: RestoreScope, replacesTheTree: Bool
    ) async -> RestoreOutcome {
        guard let descriptor = BackupTargets.load().first(where: { $0.id == row.targetId }),
            let provider = await BackupTargets.provider(for: descriptor)
        else { return .failed("this target is not configured on this device") }
        let outcome = await RestoreCoordinator.shared.restore(
            row, into: container, provider: provider, descriptor: descriptor,
            scope: scope, replacesTheTree: replacesTheTree)
        await load()
        return outcome
    }

    // MARK: - The leftovers of 11.12

    func deleteTheTrees() {
        for url in leftovers.trees {
            try? FileManager.default.removeItem(at: url)
        }
        leftovers = RestoreLeftovers.inside(container.url)
    }

    func deleteTheFiles() {
        for url in leftovers.files {
            try? FileManager.default.removeItem(at: url)
        }
        leftovers = RestoreLeftovers.inside(container.url)
    }
}
