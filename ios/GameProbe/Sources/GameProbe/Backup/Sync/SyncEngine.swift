import Foundation

/// The six steps of the replication pass of SPEC 10.5.
///
/// The pass reads every copy of the group on every configured
/// target, merges them, applies the merged values to this device,
/// then writes its own copy back to each target that does not hold
/// the current heads.
///
/// A target is a mailbox and nothing more. No device answers, no
/// device locks, and a target that fails takes nothing from the
/// others.
@MainActor
public final class SyncEngine {

    /// What one pass did.
    public enum Outcome: Equatable, Sendable {
        case done
        /// This device holds no group, or no target takes a copy.
        case nothingToDo
        /// Step 4 writes the merged values to this device, and those
        /// writes post the news a local change posts. A pass that
        /// finds nothing new of its own stops, so no pass asks for
        /// the next one.
        case noLocalNews
        /// A join landed while the pass ran, so the pass that
        /// follows reads the new group whole.
        case runAgain
        case failed(String)
    }

    private let document: any SyncDocumentStore
    private let targets: any SyncTargets
    private let state: any SyncStateStore
    private let local: any SyncLocalValuesStore
    /// This device's own record, per 10.5 step 1.
    private let device: DeviceRecord
    private let namespaceId: String
    private let now: @MainActor () -> Date
    /// What each pass merged. The device checks of ticket 020 read
    /// it, and nothing else does.
    private let didMerge: @MainActor (SyncDocumentModel, [String]) -> Void
    private let note: @MainActor (String) -> Void

    /// What this device held at the last pass.
    private var lastLocalValues: SyncDocumentModel?

    public init(
        document: any SyncDocumentStore,
        targets: any SyncTargets,
        state: any SyncStateStore,
        local: any SyncLocalValuesStore,
        device: DeviceRecord,
        namespaceId: String,
        /// The engine takes its clock as an input, because no rule
        /// of section 10 reads the wall clock.
        now: @escaping @MainActor () -> Date,
        didMerge: @escaping @MainActor (SyncDocumentModel, [String]) -> Void = { _, _ in },
        note: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.document = document
        self.targets = targets
        self.state = state
        self.local = local
        self.device = device
        self.namespaceId = namespaceId
        self.now = now
        self.didMerge = didMerge
        self.note = note
    }

    // MARK: - One pass

    public func run(_ trigger: SyncTrigger) async -> Outcome {
        guard let groupId = state.state().groupId else { return .nothingToDo }
        let enabled = targets.enabled()
        guard !enabled.isEmpty else { return .nothingToDo }

        document.load()
        guard let held = try? document.model() else {
            return .failed("the local document could not be read")
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
        updateIdentities { mine = local.read(identities: &$0) }
        if case .afterALocalChange = trigger, mine == lastLocalValues { return .noLocalNews }
        lastLocalValues = mine
        if publishes {
            try? document.write(held.overlaid(with: mine))
        }

        for descriptor in enabled {
            await merge(from: descriptor, groupId: groupId)
        }

        guard let merged = try? document.model() else {
            return .failed("the local document could not be read")
        }
        updateIdentities { local.apply(merged, identities: &$0) }

        guard publishes, !SyncCopyValidation.readsButDoesNotPublish(merged) else {
            return .failed("this build reads the document but does not write it")
        }
        do {
            try document.save()
        } catch {
            return .failed("the local document could not be saved: \(error)")
        }

        // A join that landed during this pass left the group this
        // pass read. Nothing of it goes to the new group.
        guard state.state().groupId == groupId else { return .runAgain }
        await publish(groupId: groupId, to: enabled)
        didMerge(merged, document.heads())
        return .done
    }

    // MARK: - Steps 1 and 2: read and merge

    private func merge(from descriptor: TargetDescriptor, groupId: String) async {
        let namespaces = await targets.namespaces(of: descriptor)
        let progress =
            state.state().progress(ofTarget: descriptor.id)
            ?? SyncTargetProgress(targetId: descriptor.id)

        for namespace in namespaces where namespace.id != namespaceId {
            // A copy of another group belongs to another person, per
            // 10.4, so the pass never reads it.
            guard namespace.record?.syncGroupId == groupId, let object = namespace.document,
                progress.readsAgain(namespaceId: namespace.id, modifiedAt: object.modifiedAt)
            else { continue }
            guard let bytes = await targets.read(object.path, from: descriptor) else { continue }
            let before = (try? document.model())?.layoutProfiles ?? [:]

            if case .failure(let rejection) = document.merge(bytes) {
                note("\(namespace.id) changed nothing: \(rejection)")
                continue
            }
            rebuildConflicts(
                before: before, deviceName: namespace.record?.name ?? "another device")
            if let modifiedAt = object.modifiedAt {
                updateState("what this pass read of \(descriptor.label)") {
                    $0.saw(namespaceId: namespace.id, at: modifiedAt, targetId: descriptor.id)
                }
            }
        }
    }

    /// The profile rule of 10.6: the merged winner keeps the name,
    /// and the version that lost becomes a profile of its own, so no
    /// edit disappears.
    private func rebuildConflicts(before: [String: SyncProfile], deviceName: String) {
        guard let after = try? document.model() else { return }
        var model = after
        var didChange = false

        for (id, winner) in after.liveProfiles {
            let losing = document.losingControls(profileId: id)
            guard !losing.isEmpty else { continue }
            var version = winner
            version.controls.merge(losing) { _, lost in lost }
            // The losing value is this device's own where it matches
            // what the document held before the merge.
            let mineLost = losing.contains { before[id]?.controls[$0.key] == $0.value }
            let (conflictId, profile) = SyncProfileConflict.conflictProfile(
                id: id, losing: version,
                deviceName: mineLost ? device.name : deviceName)
            model.layoutProfiles[conflictId] = profile
            document.resolveControls(profileId: id, keys: Array(losing.keys))
            didChange = true
        }

        guard didChange else { return }
        try? document.write(model)
    }

    // MARK: - Steps 5 and 6: write the copy back

    private func publish(groupId: String, to enabled: [TargetDescriptor]) async {
        let heads = document.heads()
        let needed = Set(
            SyncReplication.targetsNeedingACopy(
                enabled: enabled.map(\.id), progress: state.state().targets, heads: heads))
        guard !needed.isEmpty else { return }

        // A target is a mailbox, so the copies go out together.
        var copies: [(TargetDescriptor, Task<Bool, Never>)] = []
        for descriptor in enabled where needed.contains(descriptor.id) {
            copies.append(
                (descriptor, Task { await self.publish(to: descriptor, groupId: groupId) }))
        }

        for (descriptor, copy) in copies where await copy.value {
            updateState("the confirmed heads of \(descriptor.label)") {
                $0.confirm(targetId: descriptor.id, heads: heads)
            }
        }
    }

    /// One target takes the copy, or it does not. A target that
    /// fails takes nothing from the others, per 10.5.
    private func publish(to descriptor: TargetDescriptor, groupId: String) async -> Bool {
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: namespaceId)
        if let reason = await targets.putTheDocument(to: paths.syncDocumentFile, on: descriptor) {
            note("\(descriptor.label) took no copy: \(reason)")
            return false
        }
        await writeTheDeviceRecord(groupId: groupId, paths: paths, target: descriptor)
        return true
    }

    /// The group id rides `device.json`, per 10.5 step 1. A pass
    /// that never runs a backup still has to leave it, or a second
    /// device of the same person finds no group to join.
    private func writeTheDeviceRecord(
        groupId: String, paths: BackupNamespacePaths, target: TargetDescriptor
    ) async {
        let date = now()
        let known = await targets.read(paths.deviceFile, from: target)
            .flatMap { try? DeviceRecord.decode(json: $0) }
        var record = known ?? device
        if known == nil { record.lastWriteAt = date }
        record.syncGroupId = groupId
        record.syncUpdatedAt = date
        guard let data = try? record.jsonData() else { return }
        _ = await targets.write(data, to: paths.deviceFile, on: target)
    }

    // MARK: - The state files

    private func updateState(_ what: String, _ change: (inout SyncState) -> Void) {
        do {
            try state.update(change)
        } catch {
            note("\(what) was not saved: \(error)")
        }
    }

    private func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) {
        do {
            try state.updateIdentities(change)
        } catch {
            note("the profile identities were not saved: \(error)")
        }
    }
}
