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

    private var isRunning = false
    /// Whether a pass arrived while one ran, per the rerun below.
    private var asksAgain = false
    private var didStart = false
    private var wait: Task<Void, Never>?

    // MARK: - The two triggers of 10.11

    /// The scene delegate calls this once.
    func start() {
        guard !didStart else { return }
        didStart = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(after: 0) }
        }
        center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(after: SyncPass.localChangeWait) }
        }
        center.addObserver(
            forName: .layoutProfileDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncPass.shared.schedule(after: SyncPass.localChangeWait) }
        }
        runTheDeviceCheck()
        schedule(after: 0)
    }

    /// The launch arguments the device checks of ticket 020 use.
    ///
    /// `-syncJoin YES` joins the first group a target holds, which
    /// is check 1 with no sheet. `-syncDump YES` writes what the
    /// merged document carries to the backup log, which is how
    /// checks 2 to 5 read what crossed between two devices.
    private func runTheDeviceCheck() {
        dumps = UserDefaults.standard.bool(forKey: "syncDump")
        guard UserDefaults.standard.bool(forKey: "syncJoin") else { return }
        Task {
            guard case .confirm(let group) = await SyncJoin.ask() else {
                self.log("no target holds a group to join")
                return
            }
            SyncJoin.join(group)
            self.log("joined \(group.groupId) with \(group.deviceNames.joined(separator: ", "))")
        }
    }

    /// Whether each pass writes what the document carries to the
    /// log, for the device checks of ticket 020.
    private var dumps = false

    private func dump(_ model: SyncDocumentModel, heads: [String]) {
        guard dumps else { return }
        log("heads \(heads.joined(separator: " "))")
        log("schema \(model.schemaVersion), writer \(model.minimumWriterVersion)")
        for (key, value) in model.preferences.sorted(by: { $0.key < $1.key }) {
            log("preference \(key) = \(value)")
        }
        for (id, binding) in model.controllerBindings.sorted(by: { $0.key < $1.key }) {
            log("binding \(id) = \(binding)")
        }
        for (id, profile) in model.layoutProfiles.sorted(by: { $0.key < $1.key }) {
            let state = profile.isDeleted ? "deleted" : "\(profile.controls.count) controls"
            log("profile \(id) \"\(profile.name)\" \(state)")
        }
        for id in model.targetDescriptors.keys.sorted() {
            log("descriptor \(id)")
        }
    }

    /// A local change waits, because a settings screen writes a key
    /// on every keystroke and every drag.
    static let localChangeWait: Double = 15

    /// The pass this device asks for next. A second ask inside the
    /// wait replaces the first.
    func schedule(after seconds: Double) {
        // The pass writes preferences itself, and a play session
        // writes them too. Neither one asks for a pass of its own.
        if seconds > 0, BackupDeviceConditions.isSessionLive { return }
        if seconds > 0, isRunning {
            asksAgain = true
            return
        }
        wait?.cancel()
        wait = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            self?.wait = nil
            await self?.run()
        }
    }

    /// One pass. It answers nothing, because the user never waits
    /// for it, per 10.11.
    func run() async {
        guard !isRunning else {
            // The news that asked for this pass arrived after the
            // running one read the targets, so it runs again after.
            asksAgain = true
            return
        }
        isRunning = true
        defer {
            isRunning = false
            if asksAgain {
                asksAgain = false
                schedule(after: 0)
            }
        }

        let state = SyncStore.state()
        guard let groupId = state.groupId else { return }
        let targets = BackupTargets.load().filter { !$0.isPaused }
        guard !targets.isEmpty else { return }

        let document = localDocument(actorId: state.actorId)
        guard let held = try? SyncDocument.model(of: document) else {
            log("the local document could not be read")
            return
        }
        var identities = SyncStore.identities()

        // Step 3 writes the document onto this device, so a local
        // value that differs from the document is a change the user
        // made since the last pass. It goes in before the merge. A
        // copy that arrived first would write over it, and the user
        // would watch their change come undone.
        //
        // A document a newer Empo wrote still applies here. This
        // build only stops writing to it, per 10.10.
        let publishes = !SyncCopyValidation.readsButDoesNotPublish(held)
        if publishes {
            let mine = SyncLocalValues.current(identities: &identities)
            try? SyncDocument.write(held.overlaid(with: mine), to: document)
        }

        for descriptor in targets {
            await merge(from: descriptor, groupId: groupId, into: document)
        }

        guard let merged = try? SyncDocument.model(of: document) else {
            log("the local document could not be read")
            return
        }
        SyncLocalValues.apply(merged, identities: &identities)
        SyncStore.save(identities)

        guard publishes, !SyncCopyValidation.readsButDoesNotPublish(merged) else {
            log("this build reads the document but does not write it")
            return
        }
        do {
            try document.save().write(to: BackupRoot.syncDocumentFile, options: .atomic)
        } catch {
            log("the local document could not be saved: \(error)")
            return
        }

        // A join that landed during this pass left the group this
        // pass read. Nothing of it goes to the new group, and the
        // pass that follows reads the new one whole.
        guard SyncStore.state().groupId == groupId else {
            asksAgain = true
            return
        }
        await publish(document, groupId: groupId, targets: targets)
        dump(merged, heads: SyncDocument.heads(of: document))
    }

    // MARK: - Steps 1 and 2: read and merge

    private func localDocument(actorId: String) -> Document {
        guard let bytes = try? Data(contentsOf: BackupRoot.syncDocumentFile),
            let document = try? SyncDocument.open(bytes, actorId: actorId)
        else { return SyncDocument.make(actorId: actorId) }
        return document
    }

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
                SyncStore.update {
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

        for descriptor in targets where needed.contains(descriptor.id) {
            guard let provider = await BackupTargets.provider(for: descriptor) else { continue }
            let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
            do {
                try await provider.put(
                    localFile: BackupRoot.syncDocumentFile, path: paths.syncDocumentFile)
                guard try await provider.confirm(path: paths.syncDocumentFile) == .confirmed else {
                    continue
                }
            } catch {
                log("\(descriptor.label) took no copy: \(error)")
                continue
            }
            await writeTheDeviceRecord(groupId: groupId, paths: paths, provider: provider)
            SyncStore.update { $0.confirm(targetId: descriptor.id, heads: heads) }
        }
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

    private func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("SyncPass", message)
    }
}
