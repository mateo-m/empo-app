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
    private let note: @MainActor (String) -> Void

    /// What this device held at the last pass.
    private var lastLocalValues: SyncDocumentModel?
    private typealias SeenCopy = (
        namespaceId: String, modifiedAt: Date, sizeBytes: Int64, targetId: String
    )

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
        note: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.document = document
        self.targets = targets
        self.state = state
        self.local = local
        self.device = device
        self.namespaceId = namespaceId
        self.now = now
        self.note = note
    }

    // MARK: - One pass

    public func run(_ trigger: SyncTrigger) async -> Outcome {
        let current: SyncState
        do {
            current = try state.state()
        } catch {
            return .failed("the sync state could not be read: \(error)")
        }
        guard let groupId = current.groupId else { return .nothingToDo }
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
        // A document with no history yet, after a join or on a new
        // device, takes the group's copies first. A local write would
        // make root maps of its own, and Automerge keeps one of two
        // maps that never shared a history, so one side's keys would
        // vanish.
        let isNew = document.heads().isEmpty
        if isNew {
            // A lost document takes its history with it. What this
            // device read and confirmed belongs to that history, as on
            // a join, so the pass reads every copy again.
            do {
                try state.update { $0.targets = [] }
            } catch {
                return .failed("the progress of the lost history was not cleared: \(error)")
            }
        }
        var mine = SyncDocumentModel()
        if let failure = updateIdentities({ mine = local.read(identities: &$0) }) {
            return failure
        }
        if case .afterALocalChange = trigger, mine == lastLocalValues { return .noLocalNews }
        // Order: the restore saves this list, the pass saves the document, then it clears the list. An
        // entry the held document lacks already went out, so it leaves the list before the merge can
        // bring the key back. A new document keeps all.
        let removed = isNew
            ? current.removedPreferenceKeys
            : current.removedPreferenceKeys.filter { held.preferences[$0] != nil }
        let wentOut = current.removedPreferenceKeys.filter { !removed.contains($0) }
        if !wentOut.isEmpty {
            do {
                try state.update { $0.removedPreferenceKeys.removeAll { wentOut.contains($0) } }
            } catch {
                return .failed("the removals that already went out were not cleared: \(error)")
            }
        }
        let removedBindings = current.heldBindingIds.filter {
            mine.controllerBindings[$0] == nil
        }
        if publishes, !isNew {
            do {
                try document.write(held.overlaid(
                    with: mine, removingPreferences: removed, removingBindings: removedBindings))
            } catch {
                return .failed("the local change could not be written: \(error)")
            }
        }

        var seen: [SeenCopy] = []
        var readEveryCopy = true
        for descriptor in enabled {
            let read = await merge(from: descriptor, groupId: groupId)
            seen += read.seen
            readEveryCopy = readEveryCopy && read.isComplete
        }
        // A new document that missed a copy would start a history of
        // its own, and a later merge would hide one side's root maps.
        if isNew, !readEveryCopy {
            return .failed("a new document waits for every copy of the group")
        }

        if isNew, let fetched = try? document.model(),
            !SyncCopyValidation.readsButDoesNotPublish(fetched)
        {
            try? document.write(fetched.overlaid(
                with: mine, removingPreferences: removed, removingBindings: removedBindings,
                keepsTheirs: true))
        }

        guard let merged = try? document.model() else {
            return .failed("the local document could not be read")
        }
        // A change made during the downloads, such as a settings
        // restore, is not in `mine`, and the apply would undo it.
        var latest = SyncDocumentModel()
        if let failure = updateIdentities({ latest = local.read(identities: &$0) }) {
            return failure
        }
        guard latest == mine else { return .runAgain }
        // A build that may not write leaves a removal out of the
        // document, so the apply drops it here.
        let applied = merged.removing(
            preferences: removed, bindings: removedBindings, absentFrom: mine)
        if let failure = updateIdentities({ local.apply(applied, identities: &$0) }) {
            return failure
        }

        guard publishes, !SyncCopyValidation.readsButDoesNotPublish(merged) else {
            return .failed("this build reads the document but does not write it")
        }
        do {
            try document.save()
        } catch {
            return .failed("the local document could not be saved: \(error)")
        }
        // Only a saved pass counts as read. A pass that stops before
        // the save reads the same copies and local values again.
        var after = SyncDocumentModel()
        if let failure = updateIdentities({ after = local.read(identities: &$0) }) {
            return failure
        }
        lastLocalValues = after
        updateState("the bindings this device holds") {
            $0.heldBindingIds = after.controllerBindings.keys.sorted()
        }
        if !seen.isEmpty {
            updateState("what this pass read") { state in
                for copy in seen {
                    state.saw(
                        namespaceId: copy.namespaceId, at: copy.modifiedAt,
                        sizeBytes: copy.sizeBytes, targetId: copy.targetId)
                }
            }
        }
        if !current.removedPreferenceKeys.isEmpty {
            updateState("the removed preferences") {
                $0.removedPreferenceKeys.removeAll { current.removedPreferenceKeys.contains($0) }
            }
        }

        // A join that landed during this pass left the group this
        // pass read. Nothing of it goes to the new group.
        guard (try? state.state())?.groupId == groupId else { return .runAgain }
        await publish(groupId: groupId, to: enabled)
        return .done
    }

    // MARK: - Steps 1 and 2: read and merge

    private func merge(
        from descriptor: TargetDescriptor, groupId: String
    ) async -> (seen: [SeenCopy], isComplete: Bool) {
        var seen: [SeenCopy] = []
        var isComplete = true
        guard let namespaces = await targets.namespaces(of: descriptor),
            let held = try? state.state()
        else { return ([], false) }
        let progress =
            held.progress(ofTarget: descriptor.id) ?? SyncTargetProgress(targetId: descriptor.id)

        for namespace in namespaces where namespace.id != namespaceId {
            // A copy whose device record did not read may be one of
            // this group.
            guard let record = namespace.record else {
                if namespace.document != nil { isComplete = false }
                continue
            }
            // A copy of another group belongs to another person, per
            // 10.4, so the pass never reads it.
            guard record.syncGroupId == groupId, let object = namespace.document,
                progress.readsAgain(namespaceId: namespace.id, copy: object)
            else { continue }
            guard let bytes = await targets.read(object.path, from: descriptor) else {
                isComplete = false
                continue
            }
            let before = (try? document.model())?.layoutProfiles ?? [:]

            if case .failure(let rejection) = document.merge(bytes) {
                note("\(namespace.id) changed nothing: \(rejection)")
                isComplete = false
                continue
            }
            rebuildConflicts(
                before: before, deviceName: namespace.record?.name ?? screenText("another device"))
            if let modifiedAt = object.modifiedAt {
                seen.append((namespace.id, modifiedAt, object.sizeBytes, descriptor.id))
            }
        }
        return (seen, isComplete)
    }

    /// The profile rule of 10.6: the merged winner keeps the name,
    /// and the version that lost becomes a profile of its own, so no
    /// edit disappears.
    private func rebuildConflicts(before: [String: SyncProfile], deviceName: String) {
        guard let after = try? document.model() else { return }
        var model = after
        var resolved: [String: [String]] = [:]

        for (id, winner) in after.liveProfiles {
            let versions = document.losingControls(profileId: id)
            for losing in versions {
                var version = winner
                version.controls.merge(losing) { _, lost in lost }
                // The losing value is this device's own where it
                // matches what the document held before the merge.
                let mineLost = losing.contains { before[id]?.controls[$0.key] == $0.value }
                let (conflictId, profile) = SyncProfileConflict.conflictProfile(
                    id: id, losing: version,
                    deviceName: mineLost ? device.name : deviceName)
                model.layoutProfiles[conflictId] = profile
            }
            let keys = Set(versions.flatMap(\.keys))
            if !keys.isEmpty { resolved[id] = keys.sorted() }
        }

        guard !resolved.isEmpty else { return }
        // Resolving drops the losing values, so it waits until the
        // profiles that keep them are in the document.
        do {
            try document.write(model)
        } catch {
            note("the conflict profiles were not written: \(error)")
            return
        }
        for (id, keys) in resolved.sorted(by: { $0.key < $1.key }) {
            document.resolveControls(profileId: id, keys: keys)
        }
    }

    // MARK: - Steps 5 and 6: write the copy back

    private func publish(groupId: String, to enabled: [TargetDescriptor]) async {
        let heads = document.heads()
        guard let held = try? state.state() else { return }
        let needed = Set(
            SyncReplication.targetsNeedingACopy(
                enabled: enabled.map(\.id), progress: held.targets, heads: heads))
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
        guard await writeTheDeviceRecord(groupId: groupId, paths: paths, target: descriptor) else {
            note("\(descriptor.label) took no device record")
            return false
        }
        return true
    }

    /// The group id rides `device.json`, per 10.5 step 1. A pass
    /// that never runs a backup still has to leave it, or a second
    /// device of the same person finds no group to join.
    private func writeTheDeviceRecord(
        groupId: String, paths: BackupNamespacePaths, target: TargetDescriptor
    ) async -> Bool {
        let date = now()
        let known = await targets.read(paths.deviceFile, from: target)
            .flatMap { try? DeviceRecord.decode(json: $0) }
        var record = known ?? device
        if known == nil { record.lastWriteAt = date }
        record.syncGroupId = groupId
        record.syncUpdatedAt = date
        guard let data = try? record.jsonData() else { return false }
        return await targets.write(data, to: paths.deviceFile, on: target)
    }

    // MARK: - The state files

    private func updateState(_ what: String, _ change: (inout SyncState) -> Void) {
        do {
            try state.update(change)
        } catch {
            note("\(what) was not saved: \(error)")
        }
    }

    /// An id that does not save is made again on the next read, so
    /// the pass stops.
    private func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) -> Outcome? {
        do {
            try state.updateIdentities(change)
            return nil
        } catch {
            return .failed("the profile identities were not saved: \(error)")
        }
    }
}
