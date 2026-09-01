import Automerge
import Foundation
import GameProbe
import UIKit

/// The six steps of the replication pass of SPEC 10.5.
///
/// The pass runs when Empo opens and after a local change. It reads
/// every copy of the group on every configured target, merges them,
/// applies the merged values to this device, then writes its own
/// copy back to each target that does not hold the current heads.
///
/// A target is a mailbox and nothing more. No device answers, no
/// device locks, and a target that fails takes nothing from the
/// others.
@MainActor
final class SyncPass {

    static let shared = SyncPass()

    /// Why a pass runs, per 10.11.
    enum Trigger {
        /// Empo opened, or a join or a restore asked for a pass. It
        /// always reads every target.
        case now
        /// The user changed a setting, a binding, or a layout. It
        /// waits, because a settings screen writes a key on every
        /// keystroke and every drag.
        case afterALocalChange
    }

    /// What the pass is doing.
    private enum State {
        /// `start()` has not run, so no news reaches the pass yet.
        case new
        case idle
        /// A pass is due, and the task waits for it.
        case waiting(Task<Void, Never>)
        /// A pass is in flight. News that arrives now asks for the
        /// pass that follows it.
        case running(newsArrived: Bool)
    }

    private var state = State.new
    /// What this device held at the last pass. Step 4 writes the
    /// merged values here, and those writes post the news a local
    /// change posts, so the pass compares before it runs again.
    private var lastLocalValues: SyncDocumentModel?

    // MARK: - The two triggers of 10.11

    /// The scene delegate calls this once.
    func start() {
        guard case .new = state else { return }
        state = .idle
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.now) }
        }
        center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.afterALocalChange) }
        }
        center.addObserver(
            forName: .layoutProfileDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(.afterALocalChange) }
        }
        SyncDeviceCheck.run()
        schedule(.now)
    }

    /// How long a local change waits.
    static let localChangeWait: Double = 15

    /// The pass this device asks for next. A second ask inside the
    /// wait replaces the first.
    func schedule(_ trigger: Trigger) {
        // A play session writes preferences of its own, and it does
        // not ask for a pass.
        if trigger == .afterALocalChange, BackupDeviceConditions.isSessionLive { return }
        switch state {
        case .new:
            return
        case .running:
            state = .running(newsArrived: true)
        case .waiting(let task):
            task.cancel()
            state = .waiting(waitThenRun(trigger))
        case .idle:
            state = .waiting(waitThenRun(trigger))
        }
    }

    private func waitThenRun(_ trigger: Trigger) -> Task<Void, Never> {
        Task { [weak self] in
            if trigger == .afterALocalChange {
                try? await Task.sleep(for: .seconds(Self.localChangeWait))
            }
            guard !Task.isCancelled else { return }
            await self?.run(trigger)
        }
    }

    /// One pass. It answers nothing, because the user never waits
    /// for it, per 10.11.
    func run(_ trigger: Trigger = .now) async {
        if case .running = state {
            // The news that asked for this pass arrived after the
            // running one read the targets, so it runs again after.
            state = .running(newsArrived: true)
            return
        }
        state = .running(newsArrived: false)
        defer { runTheNextPass() }
        await pass(trigger)
    }

    /// The pass that follows, where news arrived while this one ran.
    private func runTheNextPass() {
        guard case .running(let newsArrived) = state else { return }
        state = .idle
        if newsArrived { schedule(.now) }
    }

    private func pass(_ trigger: Trigger) async {
        let sync = SyncStore.state()
        guard let groupId = sync.groupId else { return }
        let targets = BackupTargets.load().filter { !$0.isPaused }
        guard !targets.isEmpty else { return }

        let document = SyncDocumentFile.read(actorId: sync.actorId)
        guard let held = try? SyncDocument.model(of: document) else {
            log("the local document could not be read")
            return
        }
        // Step 3 writes the document onto this device, so a local
        // value that differs from the document is a change the user
        // made since the last pass. It goes in before the merge. A
        // copy that arrived first would write over it, and the user
        // would watch their change come undone.
        //
        // A document a newer Empo wrote still applies here. This
        // build only stops writing to it, per 10.10.
        let publishes = !SyncCopyValidation.readsButDoesNotPublish(held)
        var mine = SyncDocumentModel()
        updateIdentities { mine = SyncLocalValues.current(identities: &$0) }
        // Step 4 writes the merged values to this device, and those
        // writes post the news a local change posts. A pass that
        // finds nothing new of its own stops here, so no pass asks
        // for the next one.
        if trigger == .afterALocalChange, mine == lastLocalValues { return }
        lastLocalValues = mine
        if publishes {
            try? SyncDocument.write(held.overlaid(with: mine), to: document)
        }

        for descriptor in targets {
            await merge(from: descriptor, groupId: groupId, into: document)
        }

        guard let merged = try? SyncDocument.model(of: document) else {
            log("the local document could not be read")
            return
        }
        updateIdentities { SyncLocalValues.apply(merged, identities: &$0) }

        guard publishes, !SyncCopyValidation.readsButDoesNotPublish(merged) else {
            log("this build reads the document but does not write it")
            return
        }
        do {
            try SyncDocumentFile.write(document)
        } catch {
            log("the local document could not be saved: \(error)")
            return
        }

        // A join that landed during this pass left the group this
        // pass read. Nothing of it goes to the new group, and the
        // pass that follows reads the new one whole.
        guard SyncStore.state().groupId == groupId else {
            state = .running(newsArrived: true)
            return
        }
        await publish(document, groupId: groupId, targets: targets)
        SyncDeviceCheck.dump(merged, heads: SyncDocument.heads(of: document))
    }

    // MARK: - Steps 1 and 2: read and merge

    private func merge(
        from descriptor: TargetDescriptor, groupId: String, into document: Document
    ) async {
        guard let provider = await BackupTargets.provider(for: descriptor),
            let mine = try? BackupKeychain.namespaceId()
        else { return }

        let namespaces = await SyncRemote.namespaces(root: descriptor.root, provider: provider)
        let progress =
            SyncStore.state().progress(ofTarget: descriptor.id)
            ?? SyncTargetProgress(targetId: descriptor.id)

        for namespace in namespaces where namespace.id != mine {
            // A copy of another group belongs to another person, per
            // 10.4, so the pass never reads it.
            guard namespace.record?.syncGroupId == groupId, let object = namespace.document,
                progress.readsAgain(namespaceId: namespace.id, modifiedAt: object.modifiedAt)
            else { continue }
            guard let bytes = await SyncRemote.read(object.path, from: provider) else { continue }
            let before = (try? SyncDocument.model(of: document))?.layoutProfiles ?? [:]
            guard mergeOneCopy(bytes, into: document, namespaceId: namespace.id) else { continue }
            rebuildConflicts(
                in: document, before: before,
                deviceName: namespace.record?.name ?? "another device")
            if let modifiedAt = object.modifiedAt {
                updateState("what this pass read of \(descriptor.label)") {
                    $0.saw(namespaceId: namespace.id, at: modifiedAt, targetId: descriptor.id)
                }
            }
        }
    }

    private func mergeOneCopy(_ bytes: Data, into document: Document, namespaceId: String) -> Bool {
        var loaded: Document?
        let result = SyncCopyValidation.check(bytes) { data in
            let copy = try Document(data)
            loaded = copy
            return try SyncDocument.model(of: copy)
        }
        switch result {
        case .failure(let rejection):
            log("\(namespaceId) changed nothing: \(rejection)")
            return false
        case .success:
            guard let loaded, (try? document.merge(other: loaded)) != nil else { return false }
            return true
        }
    }

    /// The profile rule of 10.6: the merged winner keeps the name,
    /// and the version that lost becomes a profile of its own, so no
    /// edit disappears.
    private func rebuildConflicts(
        in document: Document, before: [String: SyncProfile], deviceName: String
    ) {
        guard let after = try? SyncDocument.model(of: document) else { return }
        var model = after
        var didChange = false

        for (id, winner) in after.liveProfiles {
            guard let losing = try? SyncDocument.losingControls(of: document, profileId: id),
                !losing.isEmpty
            else { continue }
            var version = winner
            version.controls.merge(losing) { _, lost in lost }
            // The losing value is this device's own where it matches
            // what the document held before the merge.
            let mineLost = losing.contains { before[id]?.controls[$0.key] == $0.value }
            let (conflictId, profile) = SyncProfileConflict.conflictProfile(
                id: id, losing: version,
                deviceName: mineLost ? BackupDevice.name : deviceName)
            model.layoutProfiles[conflictId] = profile
            try? SyncDocument.resolveControls(
                of: document, profileId: id, keys: Array(losing.keys))
            didChange = true
        }

        guard didChange else { return }
        try? SyncDocument.write(model, to: document)
    }

    // MARK: - Steps 5 and 6: write the copy back

    private func publish(
        _ document: Document, groupId: String, targets: [TargetDescriptor]
    ) async {
        let heads = SyncDocument.heads(of: document)
        let needed = Set(
            SyncReplication.targetsNeedingACopy(
                enabled: targets.map(\.id), progress: SyncStore.state().targets, heads: heads))
        guard !needed.isEmpty, let namespaceId = try? BackupKeychain.namespaceId() else { return }

        // A target is a mailbox, so the copies go out together.
        let took = await withTaskGroup(of: TargetDescriptor?.self) { group in
            for descriptor in targets where needed.contains(descriptor.id) {
                group.addTask { @MainActor in
                    await self.publish(
                        to: descriptor, groupId: groupId, namespaceId: namespaceId)
                }
            }
            var out: [TargetDescriptor] = []
            for await descriptor in group {
                if let descriptor { out.append(descriptor) }
            }
            return out
        }

        for descriptor in took {
            updateState("the confirmed heads of \(descriptor.label)") {
                $0.confirm(targetId: descriptor.id, heads: heads)
            }
        }
    }

    /// One target takes the copy, or it does not. A target that
    /// fails takes nothing from the others, per 10.5.
    private func publish(
        to descriptor: TargetDescriptor, groupId: String, namespaceId: String
    ) async -> TargetDescriptor? {
        guard let provider = await BackupTargets.provider(for: descriptor) else { return nil }
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        do {
            try await provider.put(localFile: SyncDocumentFile.url, path: paths.syncDocumentFile)
            guard try await provider.confirm(path: paths.syncDocumentFile) == .confirmed else {
                return nil
            }
        } catch {
            log("\(descriptor.label) took no copy: \(error)")
            return nil
        }
        await writeTheDeviceRecord(groupId: groupId, paths: paths, provider: provider)
        return descriptor
    }

    /// The group id rides `device.json`, per 10.5 step 1. A pass
    /// that never runs a backup still has to leave it, or a second
    /// device of the same person finds no group to join.
    private func writeTheDeviceRecord(
        groupId: String, paths: BackupNamespacePaths, provider: some BackupProvider
    ) async {
        let now = Date()
        let known = await SyncRemote.read(paths.deviceFile, from: provider)
            .flatMap { try? DeviceRecord.decode(json: $0) }
        var record =
            known
            ?? DeviceRecord(
                deviceId: BackupDevice.id, model: BackupDevice.model, name: BackupDevice.name,
                lastWriteAt: now)
        record.syncGroupId = groupId
        record.syncUpdatedAt = now
        guard let data = try? record.jsonData() else { return }
        try? await SyncRemote.write(data, to: paths.deviceFile, with: provider)
    }

    // MARK: - The log

    /// Every write of `sync.json` and of `sync-profile-ids.json`
    /// reads the file again first. A pass runs for seconds, and a
    /// join or a profile rename lands in the middle of one.
    private func updateState(_ what: String, _ change: (inout GameProbe.SyncState) -> Void) {
        do {
            try SyncStore.update(change)
        } catch {
            log("\(what) was not saved: \(error)")
        }
    }

    private func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) {
        do {
            try SyncStore.updateIdentities(change)
        } catch {
            log("the profile identities were not saved: \(error)")
        }
    }

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("SyncPass", message)
    }
}
