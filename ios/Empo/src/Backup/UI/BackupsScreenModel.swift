import Foundation
import GameProbe
import UIKit
import UserNotifications

/// What one target row draws, with the numbers the target screen of
/// 13.8 needs beside it.
struct BackupTargetItem: Identifiable {
    var descriptor: TargetDescriptor
    var row: TargetRow
    var usage: TargetUsage
    var games: [TargetGameUsage]
    var capabilities: TargetCapabilities
    var pendingDeletions: Int
    var lastSweep: Date?

    var id: String { descriptor.id }
}

/// The adopt banner of SPEC 13.13.
struct AdoptBannerItem: Identifiable {
    var targetId: String
    var targetLabel: String
    var namespaceId: String

    var id: String { "\(targetId).\(namespaceId)" }
}

/// What the Backups screen of SPEC 13.4 reads.
///
/// The screen holds no connection. Every line it shows comes from
/// `targets.json` and from `state.sqlite`, so opening the screen
/// makes no request. The namespace list and the adopt banner are the
/// two places that list a target, and both wait for the user.
@MainActor
@Observable
final class BackupsScreenModel {

    private(set) var items: [BackupTargetItem] = []
    private(set) var status: BackupsScreenStatus?
    private(set) var history: [BackupRunRecord] = []
    private(set) var adoptBanners: [AdoptBannerItem] = []
    /// Whether the row above Backup history shows, per 13.19.
    private(set) var asksForNotifications = false
    /// Whether the sheet of 13.19 comes up after this add.
    var showsTheNotificationSheet = false

    var iCloudReach: TargetReach = .open

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Reading

    func refresh() async {
        iCloudReach = await Self.reach()
        let descriptors = BackupTargets.load()
        var items: [BackupTargetItem] = []
        let store = try? BackupStateStore(url: BackupRoot.stateDatabase)
        defer { store?.close() }

        for descriptor in descriptors {
            let capabilities = await BackupTargets.provider(for: descriptor)?.capabilities
            let status = try? store?.targetStatus(targetId: descriptor.id)
            let games = (try? store?.usage(targetId: descriptor.id)) ?? []
            let written = games.reduce(0) { $0 + $1.bytes }
            let facts = TargetRowFacts(
                descriptor: descriptor,
                reach: descriptor.provider == .iCloudDrive ? iCloudReach : .open,
                failure: status?.failure,
                failedAt: status?.failedAt,
                supportsBackgroundTransfer: capabilities?.supportsBackgroundTransfer ?? true,
                lastSuccessText: Self.lastSuccess(of: descriptor.id, store: store))
            items.append(
                BackupTargetItem(
                    descriptor: descriptor,
                    row: TargetRowRules.row(
                        facts, time: (status?.failedAt).map(BackupText.time) ?? ""),
                    usage: TargetUsageRules.usage(
                        reading: status?.quota, capBytes: descriptor.capBytes,
                        bytesWrittenHere: written),
                    games: games,
                    capabilities: capabilities ?? TargetCapabilities(),
                    pendingDeletions: ((try? store?.pendingDeletions(targetId: descriptor.id))
                        ?? []).count,
                    lastSweep: try? store?.lastSweep(targetId: descriptor.id)))
        }
        self.items = items
        self.history = (try? store?.runHistory()) ?? []
        self.status = BackupsScreenStatusRules.status(
            rows: items.map(\.row),
            lastSuccessText: history.first { $0.outcome == .success }?.finishedAt
                .map(BackupText.day))
        await readTheNotificationPermission()
    }

    private static func reach() async -> TargetReach {
        switch await ICloudDriveGate.shared.availability() {
        case .ready: return .open
        case .notSignedIn: return .accountOff
        case .noContainer: return .notInThisBuild
        }
    }

    private static func lastSuccess(of targetId: String, store: BackupStateStore?) -> String? {
        guard let runs = try? store?.runHistory() else { return nil }
        let last = runs.first { $0.targetId == targetId && $0.outcome == .success }
        return last?.finishedAt.map(BackupText.ago)
    }

    // MARK: - "Back up now", per 13.11

    /// The row states its own condition instead of greying out
    /// mutely, per 13.11.
    var backUpNowLine: String {
        let enabled = items.filter { !$0.descriptor.isPaused }
        if enabled.isEmpty { return "Every backup target is paused" }
        return "Covers every game with new data, on every target."
    }

    var canBackUpNow: Bool {
        items.contains { !$0.descriptor.isPaused }
    }

    func backUpNow() {
        BackupScheduler.shared.pressBackUpNow(.library)
    }

    /// The games this press would cover that never answered the ask
    /// of 3.5, in library order.
    ///
    /// A run skips such a game, so the press asks first and starts
    /// the run once nothing waits. The Backup sheet never fires this
    /// ask, per 13.15, and its mode row answers it instead.
    func gamesWaitingForTheAsk() async -> [BackupModeAsk] {
        let thresholds = BackupTargets.thresholds()
        guard !thresholds.isEmpty else { return [] }
        var waiting: [BackupModeAsk] = []
        for container in GameContainer.discover() {
            let resolution = await GameBackupSets.resolveMode(
                for: container, targets: thresholds)
            guard case .ask(let ask) = resolution else { continue }
            waiting.append(
                BackupModeAsk(
                    container: container,
                    gameName: Self.name(of: container),
                    ask: ask))
        }
        return waiting
    }

    private static func name(of container: GameContainer) -> String {
        let metadata = GameMetadata.load(from: container)
        return metadata.customTitle ?? metadata.baseTitle ?? container.folderName
    }

    // MARK: - Writing

    func setPaused(_ isPaused: Bool, targetId: String) async {
        var targets = BackupTargets.load()
        guard let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
        targets[index].isPaused = isPaused
        try? BackupTargets.save(targets)
        await refresh()
    }

    func setCap(_ capBytes: Int64?, targetId: String) async {
        var targets = BackupTargets.load()
        guard let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
        targets[index].capBytes = capBytes
        try? BackupTargets.save(targets)
        await refresh()
    }

    func setThreshold(_ bytes: Int64?, targetId: String) async {
        var targets = BackupTargets.load()
        guard let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
        targets[index].sizeThresholdBytes = bytes
        try? BackupTargets.save(targets)
        await refresh()
    }

    /// Removing is local-only, per 8.8 and 13.10.
    func remove(targetId: String, deleteBackups: Bool) async {
        if deleteBackups {
            await deleteThisDeviceNamespace(targetId: targetId)
        }
        try? BackupTargets.save(BackupTargets.load().filter { $0.id != targetId })
        try? BackupKeychain.removeSecret(targetId: targetId)
        if let store = try? BackupStateStore(url: BackupRoot.stateDatabase) {
            try? store.removeTarget(targetId: targetId)
            store.close()
        }
        await refresh()
    }

    /// A checked box deletes this device's namespace only, per 5.13.
    private func deleteThisDeviceNamespace(targetId: String) async {
        guard let descriptor = items.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor),
            let namespaceId = try? BackupKeychain.namespaceId()
        else { return }
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        try? await deleteEverything(under: paths.namespacePrefix, on: provider)
    }

    func deleteNamespace(_ namespaceId: String, targetId: String) async {
        guard let descriptor = items.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return }
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        try? await deleteEverything(under: paths.namespacePrefix, on: provider)
        await refresh()
    }

    private func deleteEverything(
        under prefix: String, on provider: any BackupProvider
    ) async throws {
        let objects = try await provider.list(prefix: prefix + "/")
        try await provider.delete(paths: objects.map(\.path))
    }

    // MARK: - The namespace list, per 13.9

    func namespaces(of targetId: String) async throws -> [BackupNamespaceRow] {
        guard let descriptor = items.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return [] }
        let mine = try? BackupKeychain.namespaceId()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString
        let scan = RestoreScan(provider: provider, descriptor: descriptor)
        return try await scan.namespaces(localMarkers: Self.localMarkers()).map { scanned in
            let rows = scanned.gameRows + scanned.preferencesRows
            return BackupNamespaceRow(
                namespaceId: scanned.id,
                deviceName: scanned.deviceName,
                snapshotCount: rows.count,
                totalBytes: rows.reduce(0) { $0 + $1.bytesToDownload },
                oldestSnapshotAt: rows.map(\.createdAt).min(),
                newestSnapshotAt: rows.map(\.createdAt).max(),
                isThisDevice: scanned.id == mine,
                isEarlierSpace: scanned.id != mine && scanned.deviceId == deviceId)
        }
    }

    /// The rows one namespace holds, grouped per 11.3. The trailing
    /// section carries the snapshots that match no installed game.
    func sections(of targetId: String, namespaceId: String) async -> [SnapshotGameSection] {
        guard let descriptor = items.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor),
            let scanned = try? await RestoreScan(provider: provider, descriptor: descriptor)
                .namespaces(localMarkers: Self.localMarkers())
                .first(where: { $0.id == namespaceId })
        else { return [] }
        return RestorePicker.sections(
            scanned.gameRows, among: GameIdentities.installedIdentities())
    }

    /// The marker of every installed tree, so a row can carry the
    /// version-marker flag of 11.10.
    private static func localMarkers() -> [String: SnapshotManifest.VersionMarker] {
        var markers: [String: SnapshotManifest.VersionMarker] = [:]
        for container in GameContainer.discover() {
            markers[BackupKeys.gameKey(containerFolderName: container.folderName)] =
                GameIdentities.versionMarker(for: container)
        }
        return markers
    }

    /// Restores one snapshot into the game it matches, per 11.3.
    ///
    /// `replacesTheTree` carries the version-marker answer of 11.10
    /// where that sheet fired.
    func restore(
        _ row: SnapshotRow, scope: RestoreScope, replacesTheTree: Bool = false
    ) async -> RestoreOutcome {
        guard let descriptor = items.first(where: { $0.id == row.targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return .failed("this target is not configured on this device") }
        return await RestoreCoordinator.shared.restore(
            row, into: GameIdentities.match(row.identity), provider: provider,
            descriptor: descriptor, scope: scope, replacesTheTree: replacesTheTree)
    }

    /// The banner of 13.13, from the namespaces one target holds.
    func readTheAdoptBanners(of targetId: String) async {
        guard let rows = try? await namespaces(of: targetId),
            let label = items.first(where: { $0.id == targetId })?.descriptor.displayName
        else { return }
        let banners = rows.filter { $0.isEarlierSpace }.map {
            AdoptBannerItem(targetId: targetId, targetLabel: label, namespaceId: $0.namespaceId)
        }
        adoptBanners = adoptBanners.filter { $0.targetId != targetId } + banners
    }

    func answerTheAdoptBanner(_ banner: AdoptBannerItem, adopts: Bool) {
        if adopts {
            try? BackupKeychain.adoptNamespaceId(banner.namespaceId)
        }
        adoptBanners.removeAll { $0.id == banner.id }
    }

    // MARK: - Notifications, per 13.19

    private func readTheNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        asksForNotifications = !items.isEmpty && settings.authorizationStatus != .authorized
        systemMayStillPrompt = settings.authorizationStatus == .notDetermined
    }

    private(set) var systemMayStillPrompt = true

    /// The sheet comes up after the first target, and never by
    /// itself after that.
    func askAboutNotificationsIfNeeded() {
        let asked = UserDefaults.standard.bool(forKey: DefaultsKey.backupNotificationsAsked)
        showsTheNotificationSheet = BackupNotificationRule.asksForPermission(
            configuredTargetCount: items.count, hasAsked: asked)
    }

    func answerTheNotificationSheet(_ answer: BackupNotificationAnswer) async {
        showsTheNotificationSheet = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.backupNotificationsAsked)
        let effect = BackupNotificationAsk.effect(of: answer)
        guard effect.showsTheSystemPrompt else { return }
        await BackupNotifier.spendTheSystemPrompt()
        await readTheNotificationPermission()
    }

    /// The row above Backup history, per 13.19.
    func pressTheNotificationRow() async {
        switch BackupNotificationAsk.rowAction(systemMayStillPrompt: systemMayStillPrompt) {
        case .showTheSystemPrompt:
            await BackupNotifier.spendTheSystemPrompt()
            await readTheNotificationPermission()
        case .openTheSettingsApp:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await UIApplication.shared.open(url)
        }
    }
}
