import Foundation

/// One sweep of SPEC 5.11.
public struct SweepRequest: Sendable {

    public var descriptor: TargetDescriptor
    public var namespaceId: String
    public var deviceId: String
    /// Runs even where the schedule of 5.11 would keep the sweep
    /// queued. The manual reclaim action of section 13 sets it.
    public var force: Bool

    public init(
        descriptor: TargetDescriptor,
        namespaceId: String,
        deviceId: String,
        force: Bool = false
    ) {
        self.descriptor = descriptor
        self.namespaceId = namespaceId
        self.deviceId = deviceId
        self.force = force
    }
}

public struct SweepResult: Equatable, Sendable {

    public var decision: SweepSchedule.Decision
    /// The blob paths the sweep deleted, sorted by path.
    public var deletedPaths: [String]

    public init(decision: SweepSchedule.Decision, deletedPaths: [String] = []) {
        self.decision = decision
        self.deletedPaths = deletedPaths
    }
}

/// Deleting a game and its backups, per SPEC 5.13.
public struct BackupDeleteRequest: Sendable {

    public var descriptor: TargetDescriptor
    public var namespaceId: String
    public var deviceId: String
    public var gameKey: String
    /// The game's Rescued Saves buckets. The delete writes the
    /// exclusion into each bucket's `.empo-origin.json` marker, so
    /// the saves it drained do not return to the remote on the next
    /// run. The local bucket stays on disk.
    public var rescuedBuckets: [URL]

    public init(
        descriptor: TargetDescriptor,
        namespaceId: String,
        deviceId: String,
        gameKey: String,
        rescuedBuckets: [URL] = []
    ) {
        self.descriptor = descriptor
        self.namespaceId = namespaceId
        self.deviceId = deviceId
        self.gameKey = gameKey
        self.rescuedBuckets = rescuedBuckets
    }
}

public enum BackupDeleteResult: Equatable, Sendable {
    /// The manifests left and the mark-and-sweep ran at once.
    case deleted(snapshotIds: [String], sweptPaths: [String])
    /// The target was unreachable, so the choice became a pending
    /// deletion, applied at the start of the next successful run.
    case pending
}

extension SnapshotEngine {

    // MARK: - The prune, per 5.10

    /// Deletes the manifests that fall out of the policy, for the
    /// stream that just closed.
    ///
    /// Manifests only. It never names a blob, per invariant 6.
    /// Deleting a manifest frees no space, and blobs leave through
    /// the sweep of 5.11.
    ///
    /// The run read `writer.json` before its first blob upload and
    /// cached it for the run, per 5.12, so the prune inside a run
    /// reads it no second time. Reading it per game is what 5.12
    /// rules out.
    func prune(
        _ context: RunContext, stream: BackupStream, kind: StreamKind, preset: RetentionPreset
    ) async -> [String] {
        let targetId = context.request.descriptor.id
        guard let ledger = try? store.snapshots(targetId: targetId, gameKey: stream.key) else {
            return []
        }
        let plan = PrunePlan.plan(ledger: ledger, kind: kind, preset: preset)
        guard !plan.drop.isEmpty else { return [] }

        let paths = plan.drop.map {
            context.paths.manifestPath(stream: stream, snapshotId: $0)
        }
        guard (try? await provider.delete(paths: paths)) != nil else { return [] }
        save(
            try store.removeSnapshots(
                targetId: targetId, gameKey: stream.key, snapshotIds: plan.drop),
            "the pruned snapshots of \(stream.key)")
        return plan.drop
    }

    /// Every stream of the run, for step 1 of the prune ladder of
    /// 5.14.
    func pruneEveryStream(_ context: RunContext) async {
        if context.request.preferences != nil {
            _ = await prune(
                context, stream: .preferences, kind: .preferences,
                preset: context.request.retentionPreset)
        }
        for game in context.request.games {
            _ = await prune(
                context, stream: game.stream,
                kind: PrunePlan.kind(hasLocalContainer: game.hasLocalContainer),
                preset: context.request.retentionPreset)
        }
    }

    // MARK: - The sweep, per 5.11

    /// Runs the mark-and-sweep when the schedule of 5.11 allows it.
    ///
    /// Ticket 007 owns when this is called. The rules are here.
    public func sweep(_ request: SweepRequest) async throws -> SweepResult {
        let targetId = request.descriptor.id
        let reading =
            provider.capabilities.canQueryQuota ? try? await provider.quota() : nil
        let decision = SweepSchedule.decide(
            lastSweepAt: try? store.lastSweep(targetId: targetId),
            now: now,
            reading: reading,
            capBytes: request.descriptor.capBytes)

        let runs = request.force || decision == .run || decision == .runOverdue
        guard runs else { return SweepResult(decision: decision) }

        let paths = BackupNamespacePaths(
            root: request.descriptor.root, namespaceId: request.namespaceId)
        let deleted = try await sweepNamespace(
            paths: paths, deviceId: request.deviceId, targetId: targetId)
        return SweepResult(decision: decision, deletedPaths: deleted)
    }

    /// Mark from every manifest in the namespace, then delete every
    /// unreferenced blob older than 7 days.
    ///
    /// It re-reads `writer.json` immediately before it starts, per
    /// 5.12, because it is the one operation that deletes blobs.
    ///
    /// An interrupted sweep is safe by construction: it deletes
    /// blobs and never manifests, so nothing records where it
    /// stopped and the next run starts the mark again.
    @discardableResult
    func sweepNamespace(
        paths: BackupNamespacePaths, deviceId: String, targetId: String
    ) async throws -> [String] {
        guard provider.capabilities.reportsObjectAge else {
            // A provider that reports no object age gets no
            // automatic sweep, per 5.11. It gets the manual reclaim
            // action of section 13, which cannot run either without
            // an age to judge the 7-day margin by.
            return []
        }

        let claim = try await fetch(paths.writerFile)
            .flatMap { try? WriterClaim.decode(json: $0) }
        if case .conflict(let other) = WriterClaimCheck.decide(
            found: claim, deviceId: deviceId, namespaceId: paths.namespaceId)
        {
            throw BackupRunStop.writerConflict(other)
        }

        let manifests = try await everyManifest(in: paths)
        let listed = try await list(prefix: paths.blobsPrefix + "/")
        let namespacePrefix = paths.namespacePrefix + "/"

        let blobs = listed.compactMap { object -> BlobObject? in
            guard let modifiedAt = object.modifiedAt,
                object.path.hasPrefix(namespacePrefix)
            else { return nil }
            return BlobObject(
                path: String(object.path.dropFirst(namespacePrefix.count)),
                modifiedAt: modifiedAt)
        }

        let doomed = SweepPlan.blobsToDelete(manifests: manifests, blobs: blobs, now: now)
        let full = doomed.map { namespacePrefix + $0 }
        if !full.isEmpty {
            do {
                try await provider.delete(paths: full)
            } catch {
                throw mapped(error)
            }
        }
        save(try store.recordSweep(targetId: targetId, at: now), "the sweep time of \(targetId)")
        return full
    }

    /// Every manifest in the namespace, for the mark of 5.11.
    ///
    /// The sweep is the one operation that lists on the backup path,
    /// per 6.3, so it is the one operation that can see manifests
    /// this device's cache never recorded.
    func everyManifest(in paths: BackupNamespacePaths) async throws -> [SnapshotManifest] {
        var manifests: [SnapshotManifest] = []
        for prefix in [paths.gamesPrefix + "/", paths.preferencesPrefix + "/"] {
            for object in try await list(prefix: prefix) {
                guard BackupNamespacePaths.snapshotId(ofManifestPath: object.path) != nil,
                    let data = try await fetch(object.path),
                    let manifest = try? SnapshotManifest.decode(compressed: data)
                else { continue }
                manifests.append(manifest)
            }
        }
        return manifests
    }

    func list(prefix: String) async throws -> [RemoteObject] {
        do {
            return try await provider.list(prefix: prefix)
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Deleting a game and its backups, per 5.13

    /// Removes one game's manifests from this device's namespace and
    /// runs the mark-and-sweep at once.
    ///
    /// The scope is this device's namespace only. It removes the
    /// game's manifests and nothing else directly, so a shared data
    /// directory a second game still names cannot leave with the
    /// first game.
    public func deleteBackups(_ request: BackupDeleteRequest) async -> BackupDeleteResult {
        for bucket in request.rescuedBuckets {
            RescuedSaves.excludeFromBackup(bucket: bucket)
        }

        let targetId = request.descriptor.id
        let paths = BackupNamespacePaths(
            root: request.descriptor.root, namespaceId: request.namespaceId)
        let stream = BackupStream(key: request.gameKey)
        let ledger = (try? store.snapshots(targetId: targetId, gameKey: request.gameKey)) ?? []
        let ids = ledger.map(\.snapshotId)

        do {
            if !ids.isEmpty {
                try await provider.delete(
                    paths: ids.map { paths.manifestPath(stream: stream, snapshotId: $0) })
            }
            forget(request.gameKey, targetId: targetId, snapshotIds: ids)
            let swept = try await sweepNamespace(
                paths: paths, deviceId: request.deviceId, targetId: targetId)
            save(
                try store.clearPendingDeletion(targetId: targetId, gameKey: request.gameKey),
                "the end of the pending deletion of \(request.gameKey)")
            return .deleted(snapshotIds: ids, sweptPaths: swept)
        } catch {
            // The local delete always proceeds. The choice becomes a
            // pending deletion, applied at the start of the next
            // successful run.
            save(
                try store.addPendingDeletion(
                    PendingDeletion(
                        targetId: targetId,
                        gameKey: request.gameKey,
                        requestedAt: now,
                        rescuedBuckets: request.rescuedBuckets.map(\.lastPathComponent))),
                "the pending deletion of \(request.gameKey)")
            return .pending
        }
    }

    /// Drops everything this device remembers about one game on one
    /// target, after the manifests left it.
    private func forget(_ gameKey: String, targetId: String, snapshotIds: [String]) {
        save(
            try store.removeSnapshots(
                targetId: targetId, gameKey: gameKey, snapshotIds: snapshotIds),
            "the deleted snapshots of \(gameKey)")
        save(
            try store.clearUploadedManifest(targetId: targetId, gameKey: gameKey),
            "the end of the manifest record of \(gameKey)")
        save(
            try store.clearCheckpoint(targetId: targetId, gameKey: gameKey),
            "the end of the checkpoint of \(gameKey)")
    }

    /// Applies the pending deletions of 5.13 at the start of a run.
    func applyPendingDeletions(_ context: RunContext) async throws {
        let targetId = context.request.descriptor.id
        let pending = (try? store.pendingDeletions(targetId: targetId)) ?? []
        for deletion in pending {
            let outcome = await deleteBackups(
                BackupDeleteRequest(
                    descriptor: context.request.descriptor,
                    namespaceId: context.paths.namespaceId,
                    deviceId: context.request.deviceId,
                    gameKey: deletion.gameKey))
            guard case .deleted = outcome else { return }
        }
    }
}
