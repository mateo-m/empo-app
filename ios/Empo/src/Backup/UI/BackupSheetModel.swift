import Foundation
import GameProbe

/// What a restore left behind in one game's container, per SPEC
/// 11.12.
struct GameLeftovers {

    /// The replaced game trees, `Game.empo-displaced` and its
    /// numbered repeats.
    var trees: [URL] = []
    var treeBytes: Int64 = 0
    /// The single files a restore moved aside.
    var files: [URL] = []
    var fileBytes: Int64 = 0
    /// The one warning of 11.12, where a single file passed three
    /// copies.
    var warning: String?

    var isEmpty: Bool { trees.isEmpty && files.isEmpty }
}

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

    func refresh() async {
        let descriptors = BackupTargets.load()
        hasATarget = !descriptors.isEmpty
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        mode = intent.mode

        readTheStatus(descriptors)
        readTheLocks()
        await readTheSizes(intent: intent)
        readTheStore(descriptors)
        leftovers = Self.leftovers(in: container)
        pendingAsks = GameSaveWatch.shared.pendingAsks(forGame: container.id)
    }

    private func readTheStatus(_ descriptors: [TargetDescriptor]) {
        let store = try? BackupStateStore(url: BackupRoot.stateDatabase)
        defer { store?.close() }
        let targets = GameBackupStatusReader.targets(
            gameKey: gameKey, descriptors: descriptors, store: store)

        status = GameBackupStatusRules.status(
            targets: targets,
            isRunning: BackupScheduler.shared.runningGameKeys.contains(gameKey),
            now: Date())
        lastSuccessAt = targets.compactMap(\.lastSuccessAt).max()
    }

    private func readTheLocks() {
        locks = BackupSheetLockRules.locks(
            runInFlight: BackupScheduler.shared.runningGameKeys.contains(gameKey),
            openGameName: EngineSessionCoordinator.shared.openGameName)
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

    private func readTheStore(_ descriptors: [TargetDescriptor]) {
        guard let store = try? BackupStateStore(url: BackupRoot.stateDatabase) else { return }
        defer { store.close() }
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
            await refresh()
            return
        }
        BackupScheduler.shared.markDirty(
            container: container, reason: BackupModeChange.dirtyReason)
        await refresh()
    }

    func setMarks(_ editor: SaveFileEditorModel) async {
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        try? editor.applied(to: intent).save(to: container.empoStateURL)
        await refresh()
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
        await refresh()
    }

    // MARK: - The restore door of 11.3

    var restoreAvailability: RestoreAvailability {
        RestoreCoordinator.shared.availability(gameKey: gameKey)
    }

    /// This game's snapshots on every target and every namespace,
    /// newest first.
    func snapshots() async -> [SnapshotRow] {
        let markers = [gameKey: GameIdentities.versionMarker(for: container)]
        var rows: [SnapshotRow] = []
        for descriptor in BackupTargets.load() {
            guard let provider = await BackupTargets.provider(for: descriptor) else { continue }
            let scan = RestoreScan(provider: provider, descriptor: descriptor)
            guard let namespaces = try? await scan.namespaces(localMarkers: markers) else {
                continue
            }
            rows += namespaces.flatMap(\.gameRows).filter { $0.identity.gameKey == gameKey }
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
        await refresh()
        return outcome
    }

    // MARK: - The leftovers of 11.12

    func deleteTheTrees() async {
        for url in leftovers.trees {
            try? FileManager.default.removeItem(at: url)
        }
        await refresh()
    }

    func deleteTheFiles() async {
        for url in leftovers.files {
            try? FileManager.default.removeItem(at: url)
        }
        await refresh()
    }

    /// Every name inside the container that carries the displaced
    /// marker of 3.2. A marked directory counts once, so the files
    /// under a replaced tree never count twice.
    static func leftovers(in container: GameContainer) -> GameLeftovers {
        let fm = FileManager.default
        var found = GameLeftovers()
        var copiesByOriginal: [String: Int] = [:]
        var queue = [container.url]

        while let directory = queue.popLast() {
            let entries =
                (try? fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in entries {
                let name = url.lastPathComponent
                let isDirectory =
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard BackupSetRules.carriesDisplacedMarker(name) else {
                    if isDirectory { queue.append(url) }
                    continue
                }
                if let original = DisplacedCopy.originalName(ofDisplaced: name) {
                    copiesByOriginal[original, default: 0] += 1
                }
                if isDirectory {
                    found.trees.append(url)
                    found.treeBytes += Self.size(of: url)
                } else {
                    found.files.append(url)
                    found.fileBytes += Self.size(of: url)
                }
            }
        }

        if let (name, count) = copiesByOriginal.max(by: { $0.value < $1.value }) {
            found.warning = RestoreLeftovers.copyWarning(fileName: name, count: count)
        }
        return found
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        return BackupSetResolver.files(under: url).reduce(0) { $0 + $1.size }
    }
}
