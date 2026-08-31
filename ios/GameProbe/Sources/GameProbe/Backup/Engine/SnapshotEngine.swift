import Foundation

/// The engine that turns a backup set into a snapshot on a target,
/// per SPEC 5.8 to 5.15 and 7.7 to 7.8.
///
/// It talks to the provider protocol of section 8 alone and never
/// branches on a provider name. It takes its clock, its filesystem
/// root, and its provider as inputs, so a test drives all three.
///
/// The write order is the design, per 5.8:
///
/// 1. Stage the save members, per 6.4.
/// 2. Upload the blobs.
/// 3. Upload the manifest, last, after every blob it names is
///    confirmed.
/// 4. Apply retention by deleting the manifests that fall out of the
///    policy.
///
/// A reader therefore never sees a dangling reference, an
/// interrupted upload only wastes space, and a run that failed
/// before its manifest landed skips step 4, so a broken run never
/// deletes history. That is invariant 7.
public actor SnapshotEngine {

    /// The largest blob the engine compresses.
    ///
    /// Rule 5 of 6.4 holds the peak cost to one file. A blob over
    /// this size stores as it is and uploads straight from its own
    /// file, so a 4 GB game asset costs no memory at all. Saves are
    /// Marshal blobs of a few MB and always take the compressed
    /// path.
    public static let compressionSizeLimit: Int64 = 32 * 1024 * 1024

    /// How many times the engine re-reads a put that came back
    /// pending, per 8.5, before it leaves the manifest for the next
    /// run.
    public static let confirmationAttempts = 3
    /// How long it waits between those reads.
    public static let confirmationWait: TimeInterval = 2

    let provider: any BackupProvider
    let store: BackupStateStore
    let localRoot: URL
    let clock: BackupClock
    private let readClock: @Sendable () -> Date
    let fm = FileManager.default

    public init(
        provider: any BackupProvider,
        store: sending BackupStateStore,
        localRoot: URL,
        clock: BackupClock = SystemBackupClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.store = store
        self.localRoot = localRoot
        self.clock = clock
        self.readClock = now
    }

    var now: Date { readClock() }

    // MARK: - One run

    /// What one run carries from stream to stream.
    struct RunContext {
        var request: BackupRunRequest
        var paths: BackupNamespacePaths
        var fanOutWidth = FormatDescriptor.version1FanOutWidth
        var didSplit = false
        var uploadedBytes: Int64 = 0
        var streams: [StreamResult] = []
        /// The quota the run read before staging, per 5.14.
        var quota: QuotaReading?
    }

    /// Runs every stream of the request against the target.
    ///
    /// It never throws. Every failure becomes an outcome plus a row
    /// in the run history of 6.6, because that row is the only
    /// written record of a transient failure and 7.11 rests on it.
    public func run(_ request: BackupRunRequest) async -> BackupRunResult {
        let startedAt = now
        // The row goes in before the first byte moves. A process
        // that dies mid-run therefore leaves a failed row, and 7.11
        // rests on that row being the written record of a transient
        // failure.
        recordRun(
            request, startedAt: startedAt, finishedAt: nil, outcome: .failed,
            uploadedBytes: 0, gameCount: 0, detail: "the run did not finish")

        var context = RunContext(
            request: request,
            paths: BackupNamespacePaths(
                root: request.descriptor.root, namespaceId: request.namespaceId))

        do {
            try await openNamespace(&context)
            try await applyPendingDeletions(&context)
            try await runStreams(&context)
        } catch let stop as BackupRunStop {
            return finish(context, startedAt: startedAt, stop: stop)
        } catch {
            return finish(
                context, startedAt: startedAt,
                stop: .rejected(message: "the run could not read a local file"))
        }
        return finish(context, startedAt: startedAt, stop: nil)
    }

    private func finish(
        _ context: RunContext, startedAt: Date, stop: BackupRunStop?
    ) -> BackupRunResult {
        let outcome: BackupRunOutcome
        if stop != nil {
            outcome = .failed
        } else if context.streams.contains(where: \.isShortOfASnapshot) {
            outcome = .partial
        } else {
            outcome = .success
        }

        let result = BackupRunResult(
            runId: context.request.runId,
            namespaceId: context.paths.namespaceId,
            outcome: outcome,
            uploadedBytes: context.uploadedBytes,
            streams: context.streams,
            stop: stop,
            didSplit: context.didSplit,
            detail: stop.map(Self.detail(of:)))

        recordRun(
            context.request, startedAt: startedAt, finishedAt: now, outcome: outcome,
            uploadedBytes: result.uploadedBytes,
            gameCount: context.streams.count, detail: result.detail)
        // The target row of 13.5 outlives this run, and a run that
        // reached the target clears what an earlier one left.
        try? store.recordTargetFailure(
            targetId: context.request.descriptor.id,
            failure: stop.flatMap(TargetFailure.of),
            at: now)
        return result
    }

    private func recordRun(
        _ request: BackupRunRequest,
        startedAt: Date,
        finishedAt: Date?,
        outcome: BackupRunOutcome,
        uploadedBytes: Int64,
        gameCount: Int,
        detail: String?
    ) {
        try? store.recordRun(
            BackupRunRecord(
                id: request.runId,
                targetId: request.descriptor.id,
                startedAt: startedAt,
                finishedAt: finishedAt,
                outcome: outcome,
                uploadedBytes: uploadedBytes,
                gameCount: gameCount,
                detail: detail))
    }

    static func detail(of stop: BackupRunStop) -> String {
        switch stop {
        case .writerConflict:
            return WriterClaimCheck.splitLine
        case .readOnlyFormat:
            return "this backup space needs a newer Empo"
        case .needsSignIn:
            return "sign in to this target again"
        case .blocked(let reason), .full(let reason):
            return reason
        case .quotaShortfall(let shortfall):
            return QuotaCheck.blockedLine(shortfall)
        case .offline:
            return "no route to this target"
        case .rejected(let message):
            return message
        }
    }

    // MARK: - The namespace, the format, and the writer claim

    /// Reads `format.json` and `writer.json`, once per run and
    /// before the first blob upload, per 5.12 and 5.16.
    private func openNamespace(_ context: inout RunContext) async throws {
        let formatData = try await fetch(context.paths.formatFile)
        if let formatData {
            let access = FormatDescriptor.targetAccess(formatJSON: formatData)
            guard access.allowsWrite else {
                guard case .readOnly(let restriction) = access else { return }
                throw BackupRunStop.readOnlyFormat(restriction)
            }
            if let descriptor = try? FormatDescriptor.decode(json: formatData) {
                context.fanOutWidth = descriptor.fanOutWidth
            }
        }

        // The claim comes before any write, per 5.12, so a run that
        // meets another writer leaves the target exactly as it found
        // it.
        try await holdTheWriterClaim(&context)

        if formatData == nil {
            // The target and the namespace are both created lazily
            // at the first write, per 5.2.
            try await put(try FormatDescriptor().jsonData(), to: context.paths.formatFile)
        }
    }

    private func holdTheWriterClaim(_ context: inout RunContext) async throws {
        let found = try await fetch(context.paths.writerFile)
            .flatMap { try? WriterClaim.decode(json: $0) }
        let decision = WriterClaimCheck.decide(
            found: found,
            deviceId: context.request.deviceId,
            namespaceId: context.paths.namespaceId)

        switch decision {
        case .proceed:
            break
        case .claim:
            try await writeClaim(&context)
        case .conflict(let claim):
            guard let resolution = context.request.writerResolution else {
                throw BackupRunStop.writerConflict(claim)
            }
            if resolution == .split {
                let fresh = context.request.splitNamespaceId ?? BackupKeys.makeNamespaceId()
                context.paths = context.paths.inNamespace(fresh)
                context.didSplit = true
                // No namespace may reference another's blobs, per
                // 5.12, so the split starts from a full upload.
                try? store.clearNamespaceState(targetId: context.request.descriptor.id)
            }
            try await writeClaim(&context)
        }

        try await put(
            try DeviceRecord(
                deviceId: context.request.deviceId,
                model: context.request.deviceModel,
                name: context.request.deviceName,
                lastWriteAt: now
            ).jsonData(),
            to: context.paths.deviceFile)
    }

    private func writeClaim(_ context: inout RunContext) async throws {
        let claim = WriterClaim(
            namespaceId: context.paths.namespaceId,
            deviceId: context.request.deviceId,
            deviceName: context.request.deviceName,
            claimedAt: now)
        try await put(try claim.jsonData(), to: context.paths.writerFile)
    }

    // MARK: - The streams

    private func runStreams(_ context: inout RunContext) async throws {
        // The prefs stream goes first on every run, per 7.8. It is
        // tiny, and it holds the controller maps and layout pins a
        // user would miss at once.
        if let preferences = context.request.preferences {
            let set = BackupSetResolver.resolveLibraryStream(preferences, fm: fm)
            try await runStream(
                &context,
                stream: .preferences,
                set: set,
                source: MemberSource(library: preferences),
                manifest: SnapshotManifest(mode: .slim, containerFolderName: ""),
                kind: .preferences,
                isOneOff: false)
        }

        for game in try order(context.request.games, targetId: context.request.descriptor.id) {
            var setRequest = game.set
            if game.isOneOffFullSnapshot { setRequest.mode = .full }
            let set = BackupSetResolver.resolve(setRequest, fm: fm)
            let header = SnapshotManifest(
                mode: set.mode,
                containerFolderName: game.identity.folderName,
                identityAlias: game.identity.aliases.last,
                versionMarker: game.versionMarker,
                sharedDataDirectory: set.sharedDataDirectory,
                rescuedSavesBuckets: set.rescuedSavesBuckets)
            try await runStream(
                &context,
                stream: game.stream,
                set: set,
                source: MemberSource(game: setRequest),
                manifest: header,
                kind: PrunePlan.kind(hasLocalContainer: game.hasLocalContainer),
                isOneOff: game.isOneOffFullSnapshot)
        }
    }

    /// The games in the order of 7.8. One game at a time, never in
    /// parallel.
    private func order(_ games: [BackupRunGame], targetId: String) throws -> [BackupRunGame] {
        var byKey: [String: BackupRunGame] = [:]
        var candidates: [RunCandidate] = []
        for game in games {
            let key = game.identity.gameKey
            byKey[key] = game
            let clock = try? store.staleness(targetId: targetId, gameKey: key)
            candidates.append(
                RunCandidate(
                    gameKey: key,
                    lastSuccessAt: clock?.lastSuccessAt,
                    lastPlayedAt: game.lastPlayedAt,
                    pendingBytes: pendingBytes(of: game, targetId: targetId)))
        }
        return RunOrdering.order(candidates, now: now).compactMap { byKey[$0.gameKey] }
    }

    /// What this game would upload now, for the third tiebreak of
    /// 7.8. It is a stat pass and it hashes nothing, per 7.7.
    private func pendingBytes(of game: BackupRunGame, targetId: String) -> Int64 {
        let previous = try? store.lastUploadedManifest(
            targetId: targetId, gameKey: game.identity.gameKey)
        let set = BackupSetResolver.resolve(game.set, fm: fm)
        let plan = SnapshotDiff.plan(members: set.members, previous: previous?.manifest)
        return plan.changed.reduce(0) { $0 + $1.size }
    }

    // MARK: - One stream

    private func runStream(
        _ context: inout RunContext,
        stream: BackupStream,
        set: GameBackupSet,
        source: MemberSource,
        manifest header: SnapshotManifest,
        kind: StreamKind,
        isOneOff: Bool
    ) async throws {
        let targetId = context.request.descriptor.id
        let previous = try? store.lastUploadedManifest(targetId: targetId, gameKey: stream.key)

        if let previous, !previous.manifest.access.allowsWrite {
            guard case .readOnly(let restriction) = previous.manifest.access else { return }
            throw BackupRunStop.readOnlyFormat(restriction)
        }

        let plan = SnapshotDiff.plan(members: set.members, previous: previous?.manifest)
        if plan.changed.isEmpty,
            !isOneOff,
            !SnapshotDiff.earnsSnapshot(entries: plan.reused, previous: previous?.manifest)
        {
            context.streams.append(StreamResult(streamKey: stream.key, outcome: .noChange))
            return
        }

        let route = stagingRoute(for: plan.changed, freeSpaceBytes: context.request.freeSpaceBytes)
        guard route != .notEnoughSpace else {
            context.streams.append(
                StreamResult(streamKey: stream.key, outcome: .notEnoughLocalSpace))
            try? markAttempt(targetId: targetId, gameKey: stream.key)
            return
        }

        try await refuseARunThatCannotFit(&context, pending: plan.changed)

        var result = StreamResult(streamKey: stream.key, outcome: .blobsOnly)
        let staging = BackupRootLayout.staging(root: localRoot)
            .appendingPathComponent(stream.key, isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var entries = plan.reused
        var confirmed: [String: BlobCompression] = [:]
        for blob in (try? store.checkpoint(targetId: targetId, gameKey: stream.key))?
            .confirmedBlobs ?? []
        {
            confirmed[blob.hash] = blob.compression
        }
        var pendingPaths: [String] = []
        let snapshotId = BackupKeys.makeSnapshotId(date: now)

        for (index, member) in plan.changed.enumerated() {
            guard let file = source.url(of: member) else { continue }
            let staged = try stage(member, from: file, route: route, into: staging, index: index)
            var entry = SnapshotManifest.Entry(
                root: member.root,
                path: member.path,
                size: staged.stamp.size,
                modifiedAt: staged.stamp.modifiedAt,
                hash: staged.hash,
                compression: .stored,
                partial: staged.partial,
                detectionSource: member.detectionSource)

            var known = confirmed[staged.hash]
            if known == nil {
                known =
                    (try? store.knownBlobCompression(
                        hash: staged.hash, targetId: targetId,
                        namespaceId: context.paths.namespaceId)) ?? nil
            }

            if let algorithm = known {
                // The blob is already on the target, so the entry
                // costs nothing. It still has to name the algorithm
                // the blob went up with, per 5.6.
                entry.compression = algorithm
            } else {
                let upload = try await uploadBlob(&context, file: staged.file, hash: staged.hash)
                entry.compression = upload.compression
                result.uploadedBytes += upload.bytes
                result.uploadedBlobCount += 1
                confirmed[staged.hash] = upload.compression
                if upload.isPending { pendingPaths.append(upload.path) }
            }

            if case .inPlace = route, SaveMemberRule.isSaveMember(member) {
                // Rule 3 of 6.4: hash, upload, re-hash, and mark the
                // path partial on a mismatch.
                let after = try? ContentHash.hexOfFile(at: staged.file)
                if after != staged.hash { entry.partial = true }
            }

            if entry.partial { result.partialPaths.append(member.path) }
            entries.append(entry)
            try? store.saveCheckpoint(
                RunCheckpoint(
                    targetId: targetId,
                    gameKey: stream.key,
                    snapshotId: snapshotId,
                    uploadedBytes: result.uploadedBytes,
                    pendingPaths: plan.changed.dropFirst(index + 1).map(\.path),
                    confirmedBlobs: confirmed
                        .map { ConfirmedBlob(hash: $0.key, compression: $0.value) }
                        .sorted { $0.hash < $1.hash },
                    updatedAt: now))
        }

        context.uploadedBytes += result.uploadedBytes

        // Content decides, per 7.7. The filter of the diff reads
        // size and mtime, so a file whose bytes never moved can
        // still reach the hash. The entry set is the test, and a run
        // that matches the last one writes no snapshot.
        guard isOneOff || SnapshotDiff.earnsSnapshot(entries: entries, previous: previous?.manifest)
        else {
            context.streams.append(StreamResult(streamKey: stream.key, outcome: .noChange))
            try? store.clearCheckpoint(targetId: targetId, gameKey: stream.key)
            return
        }

        // Step 3 of 5.8: the manifest goes last, after every blob it
        // names is confirmed. A blob still pending leaves the
        // manifest for the next run, which reuses every blob for
        // free.
        guard try await waitForConfirmations(pendingPaths) else {
            context.streams.append(result)
            try? markAttempt(targetId: targetId, gameKey: stream.key)
            return
        }

        var manifest = header
        manifest.entries = entries.sorted {
            $0.root == $1.root ? $0.path < $1.path : $0.root.rawValue < $1.root.rawValue
        }
        try await put(
            try manifest.compressedData(),
            to: context.paths.manifestPath(stream: stream, snapshotId: snapshotId))

        try? store.recordUploadedManifest(
            manifest, snapshotId: snapshotId, targetId: targetId,
            namespaceId: context.paths.namespaceId, uploadedAt: now)
        try? store.recordSnapshot(
            SnapshotLedgerEntry(
                targetId: targetId, gameKey: stream.key, snapshotId: snapshotId,
                createdAt: now, isOneOff: isOneOff))
        try? store.clearCheckpoint(targetId: targetId, gameKey: stream.key)
        try? store.clearDirty(gameKey: stream.key)
        markSuccess(targetId: targetId, gameKey: stream.key, manifest: manifest)

        result.outcome = .wroteSnapshot(snapshotId: snapshotId)
        // Step 4 of 5.8, inline at the end of the stream that just
        // closed, per 5.10.
        result.prunedSnapshotIds = await prune(
            context, stream: stream, kind: kind, preset: context.request.retentionPreset)
        context.streams.append(result)
    }

    // MARK: - Staging and hashing

    private func stagingRoute(
        for members: [BackupSetMember], freeSpaceBytes: Int64
    ) -> StagingRoute {
        let saves = members.filter(SaveMemberRule.isSaveMember)
        return StagingBudget.route(
            saveMembersBytes: saves.reduce(0) { $0 + $1.size },
            largestMemberBytes: members.map(\.size).max() ?? 0,
            freeSpaceBytes: freeSpaceBytes)
    }

    /// One member, ready to hash and upload.
    private struct StagedMember {
        var file: URL
        var stamp: FileStamp
        var hash: String
        var partial: Bool
    }

    /// Rule 1 of 6.4: stage save members only, never the whole tree.
    ///
    /// Rule 2 re-checks size and mtime against the scan. Changed
    /// once means re-stage. Changed twice means keep the copy and
    /// mark the path partial, per 5.9: its bytes are from one moment
    /// and its neighbours are from another.
    private func stage(
        _ member: BackupSetMember,
        from source: URL,
        route: StagingRoute,
        into staging: URL,
        index: Int
    ) throws -> StagedMember {
        let scanned = FileStamp(size: member.size, modifiedAt: member.modifiedAt)

        guard route == .staged, SaveMemberRule.isSaveMember(member) else {
            let stamp = BackupSetResolver.stamp(of: source, fm: fm) ?? scanned
            return StagedMember(
                file: source, stamp: stamp,
                hash: try ContentHash.hexOfFile(at: source), partial: false)
        }

        let copy = staging.appendingPathComponent("\(index)")
        var partial = false
        var stamp = scanned
        for attempt in 1...2 {
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: source, to: copy)
            stamp = BackupSetResolver.stamp(of: source, fm: fm) ?? scanned
            let recheck = StagingBudget.recheck(
                scanned: scanned, afterCopy: stamp, attempt: attempt)
            if recheck == .accepted { break }
            if recheck == .skipAndMarkPartial {
                partial = true
                break
            }
        }
        return StagedMember(
            file: copy, stamp: stamp,
            hash: try ContentHash.hexOfFile(at: copy), partial: partial)
    }

    // MARK: - Uploads

    private struct UploadedBlob {
        var compression: BlobCompression
        var bytes: Int64
        var path: String
        var isPending: Bool
    }

    /// Compresses one blob at a time into the outbox and puts it,
    /// per rule 5 of 6.4 and step 2 of 5.8.
    private func uploadBlob(
        _ context: inout RunContext, file: URL, hash: String
    ) async throws -> UploadedBlob {
        let path = context.paths.blobPath(hash: hash, fanOutWidth: context.fanOutWidth)
        let size = BackupSetResolver.stamp(of: file, fm: fm)?.size ?? 0

        var source = file
        var compression = BlobCompression.stored
        var outbox: URL?
        if size <= Self.compressionSizeLimit, let data = try? Data(contentsOf: file) {
            let encoded = BlobCodec.encode(data)
            if encoded.algorithm == .zlib {
                let url = BackupRootLayout.outbox(root: localRoot)
                    .appendingPathComponent(hash)
                try? fm.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.bytes.write(to: url, options: .atomic)
                source = url
                outbox = url
                compression = .zlib
            }
        }
        defer { if let outbox { try? fm.removeItem(at: outbox) } }

        try await put(fileAt: source, to: path, context: &context)
        let uploaded = BackupSetResolver.stamp(of: source, fm: fm)?.size ?? size
        let confirmation = (try? await provider.confirm(path: path)) ?? .pending
        return UploadedBlob(
            compression: compression, bytes: uploaded, path: path,
            isPending: confirmation == .pending)
    }

    /// Waits for the puts that came back pending, per 8.5.
    ///
    /// iCloud Drive commits and reports the object durable later.
    /// The manifest may not name a blob the remote has not confirmed,
    /// per 5.8, so a blob that stays pending ends the stream without
    /// a manifest. The next run finds the blob confirmed and reuses
    /// it for free.
    private func waitForConfirmations(_ paths: [String]) async throws -> Bool {
        var pending = paths
        var attempt = 0
        while !pending.isEmpty, attempt < Self.confirmationAttempts {
            attempt += 1
            await clock.wait(seconds: Self.confirmationWait)
            var still: [String] = []
            for path in pending {
                let confirmation = (try? await provider.confirm(path: path)) ?? .pending
                if confirmation == .pending { still.append(path) }
            }
            pending = still
        }
        return pending.isEmpty
    }

    // MARK: - The staleness clock, per 7.2

    private func markAttempt(targetId: String, gameKey: String) throws {
        var clock =
            (try? store.staleness(targetId: targetId, gameKey: gameKey))
            ?? StalenessClock(targetId: targetId, gameKey: gameKey)
        clock.lastAttemptAt = now
        try store.saveStaleness(clock)
    }

    /// A snapshot that carries a partial path resets the clock only
    /// when no partial path is a save member, per 7.2.
    private func markSuccess(targetId: String, gameKey: String, manifest: SnapshotManifest) {
        var clock =
            (try? store.staleness(targetId: targetId, gameKey: gameKey))
            ?? StalenessClock(targetId: targetId, gameKey: gameKey)
        clock.lastAttemptAt = now

        let partialSaves = manifest.entries.filter {
            $0.partial && SaveMemberRule.isSaveMember($0)
        }
        if partialSaves.isEmpty {
            clock.lastSuccessAt = now
            clock.partialSince = nil
        } else if clock.partialSince == nil {
            clock.partialSince = now
        }
        try? store.saveStaleness(clock)
    }

    // MARK: - Provider calls

    /// Reads one small object, or `nil` where the target holds none.
    func fetch(_ path: String) async throws -> Data? {
        let scratch = scratchFile()
        do {
            try await provider.get(path: path, localFile: scratch)
        } catch {
            try? fm.removeItem(at: scratch)
            if error == .notFound { return nil }
            throw mapped(error)
        }
        let data = try? Data(contentsOf: scratch)
        try? fm.removeItem(at: scratch)
        return data
    }

    /// Writes one small object.
    func put(_ data: Data, to path: String) async throws {
        let scratch = scratchFile()
        try? fm.createDirectory(
            at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: scratch, options: .atomic)
        do {
            try await provider.put(localFile: scratch, path: path)
        } catch {
            try? fm.removeItem(at: scratch)
            throw mapped(error)
        }
        try? fm.removeItem(at: scratch)
    }

    /// Puts a blob, and runs the prune ladder of 5.14 when the
    /// target answers `outOfSpace`.
    private func put(
        fileAt file: URL, to path: String, context: inout RunContext
    ) async throws {
        do {
            try await provider.put(localFile: file, path: path)
            return
        } catch {
            guard error == .outOfSpace else { throw mapped(error) }
        }

        // 1. Prune to the retention policy, because that is deletion
        //    the user already agreed to. A prune frees no space on
        //    its own, per 5.11, so the sweep that reclaims the blobs
        //    it orphaned runs at once, the way the delete of 5.13
        //    runs one.
        await pruneEveryStream(context)
        _ = try? await sweepNamespace(
            paths: context.paths, deviceId: context.request.deviceId,
            targetId: context.request.descriptor.id)

        // 2. Retry.
        do {
            try await provider.put(localFile: file, path: path)
            return
        } catch {
            guard error == .outOfSpace else { throw mapped(error) }
        }

        // 3. Stop, and mark the target blocked with a stated reason.
        //    Empo never sacrifices an older snapshot beyond the
        //    retention policy to fit a new one.
        throw BackupRunStop.full(reason: QuotaCheck.prunedAndStillFullLine)
    }

    /// Where the provider answers a space query, refuse a run that
    /// cannot fit and name the shortfall, per 5.14.
    private func refuseARunThatCannotFit(
        _ context: inout RunContext, pending: [BackupSetMember]
    ) async throws {
        guard provider.capabilities.canQueryQuota else { return }
        if context.quota == nil {
            context.quota = try? await provider.quota()
        }
        let shortfall = QuotaCheck.shortfall(
            pendingBytes: pending.reduce(0) { $0 + $1.size },
            reading: context.quota,
            capBytes: context.request.descriptor.capBytes)
        guard let shortfall else { return }
        throw BackupRunStop.quotaShortfall(shortfall)
    }

    /// The one effect of 8.4, as a run stop. A transient error keeps
    /// the run's own error, and the caller decides.
    func mapped(_ error: BackupProviderError) -> Error {
        switch error {
        case .authExpired:
            return BackupRunStop.needsSignIn
        case .permissionDenied:
            return BackupRunStop.blocked(
                reason: "this target refused the request. Sign in again with full access.")
        case .rejected(let message):
            return BackupRunStop.rejected(message: message)
        case .offline:
            return BackupRunStop.offline
        case .throttled(let retryAfter):
            return BackupRunStop.blocked(
                reason: "this target asked Empo to wait \(Int(retryAfter)) seconds")
        case .outOfSpace:
            return BackupRunStop.full(reason: QuotaCheck.prunedAndStillFullLine)
        case .notFound:
            return BackupRunStop.rejected(message: "the target lost an object Empo wrote")
        }
    }

    func scratchFile() -> URL {
        let url = BackupRootLayout.outbox(root: localRoot)
            .appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
}

extension StreamResult {

    /// Whether the stream ended without the snapshot it set out to
    /// write. The run is `partial` when any stream did, per 6.6.
    var isShortOfASnapshot: Bool {
        switch outcome {
        case .wroteSnapshot, .noChange:
            return false
        case .notEnoughLocalSpace, .blobsOnly, .failed:
            return true
        }
    }
}
