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
    var pendingDeletions: Int

    var id: String { descriptor.id }
}

/// What one namespace holds, as the browser of 13.9 lists it.
struct NamespaceContents {
    var games: [NamespaceGameRow]
    var preferences: [SnapshotRow]

    var bytes: Int64 {
        (games.flatMap(\.rows) + preferences).reduce(0) { $0 + $1.bytesToDownload }
    }
}

/// One game's snapshots in a namespace, with the name the browser
/// shows and the key the restore door reads.
struct NamespaceGameRow: Identifiable {
    /// The game key, or the empty key for the trailing "Other
    /// snapshots" section of 11.11.
    var id: String
    var name: String
    var rows: [SnapshotRow]
}

/// The writer question of SPEC 5.12, for one target.
struct WriterQuestionItem: Identifiable {
    var targetId: String
    var targetLabel: String
    var deviceName: String

    var id: String { targetId }
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

    /// `nil` until the first `refresh` returns. The screen shows the
    /// wait then, and not the empty state of 13.4.
    private(set) var items: [BackupTargetItem]?

    /// What the model's own readers use. Nothing inside waits for a
    /// screen, so an empty read before the first refresh is right.
    private var targets: [BackupTargetItem] { items ?? [] }
    private var facts: [TargetRowFacts] = []
    private var lastSuccessText: String?
    var status: BackupsScreenStatus? {
        BackupsScreenStatusRules.status(
            of: facts, games: BackupBadges.shared.clocks, lastSuccessText: lastSuccessText)
    }
    private(set) var history: [BackupRunRecord] = []
    private(set) var adoptBanners: [AdoptBannerItem] = []
    private(set) var writerQuestions: [WriterQuestionItem] = []
    /// The line of 7.11, after a split, until the user closes it.
    private(set) var showsTheSplitLine = false
    private(set) var targetsFileIsDamaged = false
    /// Whether the row above Backup history shows, per 13.19.
    private(set) var asksForNotifications = false

    var iCloudReach: TargetReach = .open

    // MARK: - Reading

    func refresh() async {
        iCloudReach = await ICloudDriveGate.shared.availability().reach
        let descriptors: [TargetDescriptor]
        do {
            descriptors = try BackupTargets.read()
            targetsFileIsDamaged = false
        } catch {
            BackupLog.line("BackupsScreenModel", "targets.json was not read: \(error)")
            descriptors = []
            targetsFileIsDamaged = true
        }
        var items: [BackupTargetItem] = []
        var facts: [TargetRowFacts] = []
        let store = try? BackupRoot.openStateStore()
        defer { store?.close() }
        let runs = (try? store?.runHistory()) ?? []

        for descriptor in descriptors {
            let capabilities = await BackupTargets.provider(for: descriptor)?.capabilities
            let status = try? store?.targetStatus(targetId: descriptor.id)
            let usage = (try? store?.usage(targetId: descriptor.id)) ?? []
            let written = usage.reduce(0) { $0 + $1.bytes }
            let games = usage.filter { $0.gameKey != BackupStream.preferencesKey }
            let row = TargetRowFacts(
                descriptor: descriptor,
                reach: descriptor.provider == .iCloudDrive ? iCloudReach : .open,
                failure: status?.lastFailure?.failure,
                failedAtText: (status?.lastFailure?.at).map(BackupText.when) ?? "",
                supportsBackgroundTransfer: capabilities?.supportsBackgroundTransfer ?? true,
                lastSuccessText: Self.lastSuccess(of: descriptor.id, in: runs),
                hasPlus: EmpoPlus.shared.hasPlus)
            facts.append(row)
            items.append(
                BackupTargetItem(
                    descriptor: descriptor,
                    row: TargetRowRules.row(row),
                    usage: TargetUsageRules.usage(
                        reading: status?.quota, capBytes: descriptor.capBytes,
                        bytesWrittenHere: written),
                    games: games,
                    pendingDeletions: ((try? store?.pendingDeletions(targetId: descriptor.id))
                        ?? []).count))
        }
        self.items = items
        self.history = runs
        let conflicts: WriterConflicts
        do {
            conflicts = try BackupRoot.writerConflicts()
        } catch {
            BackupLog.line("BackupsScreenModel", "The writer answers were not read: \(error)")
            conflicts = WriterConflicts()
        }
        writerQuestions = descriptors.compactMap { descriptor in
            conflicts.questions[descriptor.id].map {
                WriterQuestionItem(
                    targetId: descriptor.id, targetLabel: descriptor.displayName,
                    deviceName: $0.deviceName)
            }
        }
        showsTheSplitLine = conflicts.showsTheSplitLine
        // A paused location leaves the line, so its date cannot stand
        // for the locations that still run.
        let active = Set(descriptors.filter { !$0.isPaused }.map(\.id))
        self.facts = facts
        lastSuccessText = runs.first { run in
            run.end?.outcome == .success && active.contains(run.targetId)
        }?.end.map { BackupText.day($0.finishedAt) }
        await readTheNotificationPermission()
    }

    private static func lastSuccess(of targetId: String, in runs: [BackupRunRecord]) -> String? {
        let last = runs.first { $0.targetId == targetId && $0.end?.outcome == .success }
        return last?.end.map { BackupText.ago($0.finishedAt) }
    }

    // MARK: - "Back up now", per 13.11

    var canBackUpNow: Bool {
        targets.contains {
            switch $0.row.state {
            case .cannotOpen, .placeholder, .paused, .needsPlus: false
            default: true
            }
        }
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
            let resolution: BackupModeResolution
            do {
                resolution = try await GameBackupSets.resolveMode(for: container, targets: thresholds)
            } catch {
                BackupLog.line(
                    "BackupsScreenModel", "\(container.folderName) backup settings did not read: \(error)")
                continue
            }
            guard case .ask(let ask) = resolution else { continue }
            waiting.append(
                BackupModeAsk(
                    container: container,
                    gameName: BackupGameNames.name(of: container),
                    ask: ask))
        }
        return waiting
    }

    // MARK: - Writing

    enum SignInAgain {
        case checked(PermissionCheckOutcomeSheet)
        case failed(String)
    }

    private(set) var isSigningIn = false

    /// Runs the sign-in of 13.7 again, or returns `nil` when the user
    /// closed the browser or a sign-in already runs.
    func signInAgain(_ item: BackupTargetItem) async -> SignInAgain? {
        guard !isSigningIn else { return nil }
        isSigningIn = true
        defer { isSigningIn = false }
        let outcome = await BackupTargetAdd.signInAgain(item.descriptor)
        await refresh()
        switch outcome {
        case .checked(let descriptor, let result):
            return .checked(PermissionCheckOutcomeSheet(target: descriptor, result: result))
        case .failed(let line):
            return .failed(line)
        case .cancelled:
            return nil
        }
    }

    func setPaused(_ isPaused: Bool, targetId: String) async {
        await change(targetId: targetId) { $0.isPaused = isPaused }
    }

    func setCap(_ capBytes: Int64?, targetId: String) async {
        await change(targetId: targetId) { $0.capBytes = capBytes }
    }

    func setThreshold(_ bytes: Int64?, targetId: String) async {
        await change(targetId: targetId) { $0.sizeThresholdBytes = bytes }
    }

    private func change(
        targetId: String, _ edit: (inout TargetDescriptor) -> Void
    ) async {
        do {
            try BackupTargets.update { targets in
                guard let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
                edit(&targets[index])
            }
        } catch {
            BackupLog.line("BackupsScreenModel", "the change to \(targetId) was not saved: \(error)")
        }
        await refresh()
    }

    func setAsideTheDamagedTargets() async {
        do {
            try BackupTargets.setAsideTheDamagedFile()
        } catch {
            BackupLog.line("BackupsScreenModel", "targets.json was not set aside: \(error)")
        }
        await refresh()
    }

    /// Removing is local-only, per 8.8 and 13.10. It answers the
    /// line the sheet shows, or `nil` where the target went.
    ///
    /// The descriptor goes last, and nothing else runs after a
    /// failure. A target that still has its descriptor is one the
    /// user can remove again, while a descriptor that went first
    /// would leave the secret and the rows with no row to remove
    /// them from.
    func remove(targetId: String, deleteBackups: Bool) async -> String? {
        // A pass writes rows for each target it covers, so none may run
        // while the rows and the backups of this target go.
        await BackupScheduler.shared.withRunsHeld {
            await removeWhileRunsAreHeld(targetId: targetId, deleteBackups: deleteBackups)
        }
    }

    private func removeWhileRunsAreHeld(targetId: String, deleteBackups: Bool) async -> String? {
        if deleteBackups {
            do {
                try await deleteThisDeviceNamespace(targetId: targetId)
            } catch {
                BackupLog.line("BackupsScreenModel", "deleting the backups of \(targetId) failed: \(error)")
                await refresh()
                return String(localized: "Empo couldn't delete all of these backups. Try again.")
            }
        }
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            try store.removeTarget(targetId: targetId)
            do {
                try SyncStore.update { $0.forget(targetId: targetId) }
            } catch {
                // Sync stays stopped while its settings do not read, so nothing reads this target.
                BackupLog.line(
                    "BackupsScreenModel", "the sync settings do not read, so \(targetId) stays in them")
            }
            updateTheConflicts { $0.forget(targetId: targetId) }
            try BackupKeychain.removeSecret(targetId: targetId)
            BackupTargets.forget(targetId: targetId)
            try BackupTargets.update { $0.removeAll { $0.id == targetId } }
        } catch {
            BackupLog.line("BackupsScreenModel", "removing \(targetId) failed: \(error)")
            await refresh()
            return String(localized: "Empo couldn't remove this location. Try again.")
        }
        await refresh()
        return nil
    }

    /// A checked box deletes this device's namespace only, per 5.13.
    private func deleteThisDeviceNamespace(targetId: String) async throws {
        try await deleteNamespace(try BackupKeychain.namespaceId(), targetId: targetId)
    }

    func deleteNamespace(_ namespaceId: String, targetId: String) async throws {
        guard let descriptor = targets.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { throw BackupProviderError.rejected(message: "Empo couldn't open \(targetId)") }
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        defer { Task { await refresh() } }
        try await provider.deleteEverything(under: paths.namespacePrefix + "/")
    }

    // MARK: - The namespace list, per 13.9

    func namespaces(of targetId: String) async throws -> [BackupNamespaceRow] {
        guard let descriptor = targets.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return [] }
        return try await RestoreScan(provider: provider, descriptor: descriptor).namespaceRows(
            thisNamespaceId: try BackupKeychain.namespaceId(), thisDeviceId: BackupDevice.id)
    }

    /// What one namespace holds, per 11.3. The trailing game
    /// section carries the snapshots that match no installed game,
    /// and the preference snapshots are the rollback points of 10.9.
    func contents(of targetId: String, namespaceId: String) async throws -> NamespaceContents {
        guard let descriptor = targets.first(where: { $0.id == targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return NamespaceContents(games: [], preferences: []) }
        let scanned = try await RestoreScan(provider: provider, descriptor: descriptor)
            .namespace(namespaceId, localMarkers: Self.localMarkers())
        let names = BackupGameNames()
        let sections = RestorePicker.sections(
            scanned.gameRows, among: GameIdentities.installedIdentities())
        return NamespaceContents(
            games: sections.map { section in
                guard let game = section.game else {
                    return NamespaceGameRow(
                        id: "", name: RestorePicker.otherSnapshotsHeading, rows: section.rows)
                }
                return NamespaceGameRow(
                    id: game.gameKey, name: names.name(of: game), rows: section.rows)
            },
            preferences: RestorePicker.newestFirst(scanned.preferencesRows))
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
        guard let descriptor = targets.first(where: { $0.id == row.targetId })?.descriptor,
            let provider = await BackupTargets.provider(for: descriptor)
        else { return .failed(String(localized: "This location isn't set up on this device any more.")) }
        return await RestoreCoordinator.shared.restore(
            row, into: GameIdentities.match(row.identity), provider: provider,
            descriptor: descriptor, scope: scope, replacesTheTree: replacesTheTree)
    }

    /// The fresh-install flow of 11.4, where adding this target
    /// opened the door of 11.3.
    func freshInstall(after descriptor: TargetDescriptor) async -> FreshInstallScan? {
        guard let provider = await BackupTargets.provider(for: descriptor) else { return nil }
        return await RestoreCoordinator.shared.freshInstall(
            descriptor: descriptor, provider: provider, targetCount: targets.count)
    }

    /// The banner of 13.13, from the namespaces one target holds.
    func readTheAdoptBanners(of targetId: String) async {
        guard let rows = try? await namespaces(of: targetId),
            let label = targets.first(where: { $0.id == targetId })?.descriptor.displayName
        else { return }
        let banners = rows.filter { $0.isEarlierSpace }.map {
            AdoptBannerItem(targetId: targetId, targetLabel: label, namespaceId: $0.namespaceId)
        }
        adoptBanners = adoptBanners.filter { $0.targetId != targetId } + banners
    }

    func answerTheAdoptBanner(_ banner: AdoptBannerItem, adopts: Bool) {
        if adopts {
            do {
                try BackupNamespaceMove.move(to: banner.namespaceId)
            } catch {
                BackupLog.line("BackupsScreenModel", "The adopt was not saved: \(error)")
                return
            }
        }
        adoptBanners.removeAll { $0.id == banner.id }
    }

    // MARK: - The writer question, per 5.12

    /// The answer starts a run at once, so the user sees the split or
    /// the take-over happen.
    func answerTheWriterQuestion(_ item: WriterQuestionItem, resolution: WriterClaimResolution) {
        updateTheConflicts { $0.answer(targetId: item.targetId, resolution: resolution) }
        writerQuestions.removeAll { $0.id == item.id }
        backUpNow()
    }

    func closeTheSplitLine() {
        updateTheConflicts { $0.showsTheSplitLine = false }
        showsTheSplitLine = false
    }

    private func updateTheConflicts(_ change: (inout WriterConflicts) -> Void) {
        do {
            var conflicts = try BackupRoot.writerConflicts()
            change(&conflicts)
            try conflicts.write(applicationSupport: BackupRoot.layout.applicationSupport)
        } catch {
            BackupLog.line("BackupsScreenModel", "The writer answers were not saved: \(error)")
        }
    }

    // MARK: - Notifications, per 13.19

    private func readTheNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        asksForNotifications = !targets.isEmpty && settings.authorizationStatus != .authorized
        systemMayStillPrompt = settings.authorizationStatus == .notDetermined
    }

    private(set) var systemMayStillPrompt = true

    /// The sheet comes up after the first target, and never by
    /// itself after that.
    func asksAboutNotifications() -> Bool {
        let asked = UserDefaults.standard.bool(forKey: DefaultsKey.backupNotificationsAsked)
        return BackupNotificationRule.asksForPermission(
            configuredTargetCount: targets.count, hasAsked: asked)
    }

    func answerTheNotificationSheet(_ answer: BackupNotificationAnswer) async {
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
