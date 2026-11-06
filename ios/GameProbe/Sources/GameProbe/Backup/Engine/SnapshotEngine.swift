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
    /// Who reads the run plan of 13.2. The engine never draws, so a
    /// run with no observer does the same work.
    let observer: (any BackupRunObserver)?
    private let readClock: @Sendable () -> Date
    /// Where the engine writes what it could not save. The state
    /// database is a cache and a failed write never stops a run,
    /// but it must not pass in silence either.
    let note: @Sendable (String) -> Void
    let fm = FileManager.default

    public init(
        provider: any BackupProvider,
        store: sending BackupStateStore,
        localRoot: URL,
        clock: BackupClock = SystemBackupClock(),
        observer: (any BackupRunObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.provider = provider
        self.store = store
        self.localRoot = localRoot
        self.clock = clock
        self.observer = observer
        self.readClock = now
        self.note = note
    }

    /// Runs a state write the run itself does not depend on.
    func save(_ write: @autoclosure () throws -> Void, _ what: String) {
        do {
            try write()
        } catch {
            note("\(what) was not saved: \(error)")
        }
    }

    var now: Date { readClock() }

    // MARK: - One run

    /// What one run carries from stream to stream. One object per
    /// run, so no step takes it in and gives it back.
    final class RunContext {
        let request: BackupRunRequest
        /// A split moves the run to a new namespace, per 5.12.
        var paths: BackupNamespacePaths
        var fanOutWidth = FormatDescriptor.version1FanOutWidth
        var didSplit = false
        var uploadedBytes: Int64 = 0
        var streams: [StreamResult] = []
        /// The quota the run read before its first upload.
        var quota: QuotaReading?
        /// What the target has left for this run's blobs, or `nil`
        /// where no number governs. The first upload reads it.
        var room: Int64?
        var hasReadTheRoom = false
        /// What the games the run skipped for room still need.
        var shortfall: QuotaCheck.Shortfall?

        init(request: BackupRunRequest, paths: BackupNamespacePaths) {
            self.request = request
            self.paths = paths
        }
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
            uploadedBytes: 0, gameCount: 0, detail: BackupHistoryState.unfinishedLine)

        let context = RunContext(
            request: request,
            paths: BackupNamespacePaths(
                root: request.descriptor.root, namespaceId: request.namespaceId))

        do {
            try await openNamespace(context)
            try await applyPendingDeletions(context)
            try await runStreams(context)
            await sweepWhenDue(context)
            try await readTheSpaceLeft(context)
            if let shortfall = context.shortfall { throw BackupRunStop.quotaShortfall(shortfall) }
        } catch let stop as BackupRunStop {
            return finish(context, startedAt: startedAt, stop: Task.isCancelled ? .paused : stop)
        } catch BackupProviderError.permissionDenied {
            let reason = BackupProviderError.permissionDenied.line(for: request.descriptor.provider)
            return finish(
                context, startedAt: startedAt,
                stop: Task.isCancelled ? .paused : .blocked(reason: reason))
        } catch {
            // A pause cancels the upload in flight, and that error
            // arrives before the file boundary reads the cancel.
            return finish(
                context, startedAt: startedAt,
                stop: Task.isCancelled
                    ? .paused : .rejected(message: "Empo couldn't read a save file on this device."))
        }
        return finish(context, startedAt: startedAt, stop: nil)
    }

    private func finish(
        _ context: RunContext, startedAt: Date, stop: BackupRunStop?
    ) -> BackupRunResult {
        let outcome: BackupRunOutcome
        if stop == .paused || stop == .gameStarted {
            outcome = .cancelled
        } else if stop != nil {
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
            gameCount: context.streams.filter { $0.streamKey != BackupStream.preferencesKey }.count,
            detail: result.detail)
        // The run reached its end with the process alive, so it left
        // no interruption to ask about at the next launch, per 6.5.
        save(try store.clearIntent(kind: .interruptedRun), "the end of the interrupted run")
        // The target row of 13.5 outlives this run, and a run that
        // reached the target clears what an earlier one left. A pause
        // can land before the first request, so it proves nothing.
        if stop != .paused {
            save(
                try store.recordTargetFailure(
                    targetId: context.request.descriptor.id,
                    failure: stop.flatMap(TargetFailure.of),
                    at: now),
                "the target failure of \(context.request.descriptor.id)")
        }
        // The usage line of the detail screen reads this row.
        if let quota = context.quota {
            save(
                try store.recordTargetQuota(
                    targetId: context.request.descriptor.id, reading: quota, at: now),
                "the space reading of \(context.request.descriptor.id)")
        }
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
        save(
            try store.recordRun(
                BackupRunRecord(
                    id: request.runId,
                    targetId: request.descriptor.id,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    outcome: outcome,
                    uploadedBytes: uploadedBytes,
                    gameCount: gameCount,
                    detail: detail)),
            "the run history row of \(request.runId)")
    }

    static func detail(of stop: BackupRunStop) -> String {
        switch stop {
        case .writerConflict:
            return BackupNotificationRule.writerSplitLine
        case .readOnlyFormat:
            return "This backup needs a newer version of Empo."
        case .needsSignIn:
            return "Sign in to this location again."
        case .blocked(let reason), .full(let reason):
            return reason
        case .quotaShortfall(let shortfall):
            return QuotaCheck.blockedLine(shortfall)
        case .offline:
            return "Empo couldn't connect to this location."
        case .serverError:
            return "This location had a server error."
        case .throttled(let retryAfter):
            return "This location asked Empo to wait \(Int(retryAfter)) seconds."
        case .rejected(let message):
            return message
        case .gameStarted:
            return "A game started. Empo backs up the rest when you stop playing."
        case .paused:
            return "You or iOS paused the backup."
        }
    }

    // MARK: - The namespace, the format, and the writer claim

    /// Reads `format.json` and `writer.json`, once per run and
    /// before the first blob upload, per 5.12 and 5.16.
    private func openNamespace(_ context: RunContext) async throws {
        // The app sends `get` and `put` through a background session,
        // which waits for days on a server that refuses the connection.
        // `list` fails at once, so it stops the run while the user looks.
        do {
            _ = try await provider.list(prefix: context.paths.formatFile)
        } catch {
            if error != .notFound { throw mapped(error) }
        }
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
        try await holdTheWriterClaim(context)

        if formatData == nil {
            // The target and the namespace are both created lazily
            // at the first write, per 5.2.
            try await put(try FormatDescriptor().jsonData(), to: context.paths.formatFile)
        }
    }

    private func holdTheWriterClaim(_ context: RunContext) async throws {
        let decision = WriterClaimCheck.decide(
            found: try await readTheClaim(context.paths),
            deviceId: context.request.deviceId,
            namespaceId: context.paths.namespaceId)

        switch decision {
        case .proceed:
            break
        case .claim:
            // No claim means this place holds nothing this namespace
            // wrote: another account behind the same target id, or a
            // deleted folder. The blobs the store remembers are not
            // here, so the run starts from a full upload.
            save(
                try store.clearNamespaceState(targetId: context.request.descriptor.id),
                "the namespace state of a place with no claim")
            try await writeClaim(context)
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
                save(
                    try store.clearNamespaceState(targetId: context.request.descriptor.id),
                    "the namespace state the split drops")
            }
            try await writeClaim(context)
        }

        // Only a sync pass moves the sync date. The join picker reads
        // it to find the device that last changed the settings.
        let known = (try? await fetch(context.paths.deviceFile))
            .flatMap { try? DeviceRecord.decode(json: $0) }
        try await put(
            try DeviceRecord(
                deviceId: context.request.deviceId,
                model: context.request.deviceModel,
                name: context.request.deviceName,
                lastWriteAt: now,
                syncGroupId: context.request.syncGroupId,
                syncUpdatedAt: known?.syncGroupId == context.request.syncGroupId
                    ? known?.syncUpdatedAt : nil
            ).jsonData(),
            to: context.paths.deviceFile)
    }

    private func writeClaim(_ context: RunContext) async throws {
        let claim = WriterClaim(
            namespaceId: context.paths.namespaceId,
            deviceId: context.request.deviceId,
            deviceName: context.request.deviceName,
            claimedAt: now)
        try await put(try claim.jsonData(), to: context.paths.writerFile)
    }

    // MARK: - The streams

    private func runStreams(_ context: RunContext) async throws {
        let targetId = context.request.descriptor.id
        var inputs: [StreamInput] = []
        // The prefs stream goes first on every run, per 7.8. It is
        // tiny, and it holds the controller maps and layout pins a
        // user would miss at once.
        if let preferences = context.request.preferences {
            let scannedAt = now
            let set = BackupSetResolver.resolveLibraryStream(preferences, fm: fm)
            inputs.append(
                input(
                    stream: .preferences,
                    set: set,
                    source: MemberSource(library: preferences),
                    header: SnapshotManifest(
                        mode: .slim, containerFolderName: "",
                        rescuedSavesBuckets: set.rescuedSavesBuckets),
                    kind: .preferences,
                    isOneOff: false,
                    isGame: false,
                    previous: (try? store.lastUploadedManifest(
                        targetId: targetId, gameKey: BackupStream.preferences.key))?.manifest,
                    scannedAt: scannedAt))
        }
        inputs += try order(context.request.games, targetId: targetId)

        // The whole plan of 13.2 is known before the first upload, so
        // the progress never falls back when the run reaches a game
        // with more to upload.
        for input in inputs {
            await observer?.runPlanned(streamKey: input.stream.key, bytes: input.plan.changedBytes)
        }

        for input in inputs {
            if input.isGame {
                guard !Task.isCancelled else { throw BackupRunStop.paused }
                guard await observer?.runMayGoOn() ?? true else { throw BackupRunStop.gameStarted }
            }
            try await runStream(context, input)
        }
    }

    private func input(of game: BackupRunGame, targetId: String) -> StreamInput {
        let scannedAt = now
        var setRequest = game.set
        if game.isOneOffFullSnapshot { setRequest.mode = .full }
        let previous = (try? store.lastUploadedManifest(
            targetId: targetId, gameKey: game.stream.key))?.manifest
        // The app keeps its joins in memory for one launch only.
        let earlierJoins = (previous?.entries ?? [])
            .filter { $0.root == .container && $0.detectionSource == .runtimeWatch }
            .map(\.path)
        setRequest.runtimeWatchPaths = Array(
            Set(setRequest.runtimeWatchPaths).union(earlierJoins)
        ).sorted()
        let set = BackupSetResolver.resolve(setRequest, fm: fm)
        return input(
            stream: game.stream,
            set: set,
            source: MemberSource(game: setRequest),
            header: SnapshotManifest(
                mode: set.mode,
                containerFolderName: game.identity.folderName,
                identityAlias: game.identity.aliases.last,
                title: game.title,
                versionMarker: game.versionMarker,
                sharedDataDirectory: set.sharedDataDirectory,
                rescuedSavesBuckets: set.rescuedSavesBuckets),
            kind: PrunePlan.kind(hasLocalContainer: game.hasLocalContainer),
            isOneOff: game.isOneOffFullSnapshot,
            isGame: true,
            previous: previous,
            scannedAt: scannedAt)
    }

    private func input(
        stream: BackupStream,
        set: GameBackupSet,
        source: MemberSource,
        header: SnapshotManifest,
        kind: StreamKind,
        isOneOff: Bool,
        isGame: Bool,
        previous: SnapshotManifest?,
        scannedAt: Date
    ) -> StreamInput {
        StreamInput(
            stream: stream,
            source: source,
            header: header,
            kind: kind,
            isOneOff: isOneOff,
            isGame: isGame,
            previous: previous,
            plan: SnapshotDiff.plan(members: set.members, previous: previous),
            scannedAt: scannedAt)
    }

    /// The games in the order of 7.8. One game at a time, never in
    /// parallel.
    private func order(_ games: [BackupRunGame], targetId: String) throws -> [StreamInput] {
        var byKey: [String: StreamInput] = [:]
        var candidates: [RunCandidate] = []
        for game in games {
            let key = game.identity.gameKey
            let input = input(of: game, targetId: targetId)
            byKey[key] = input
            let clock = try? store.staleness(targetId: targetId, gameKey: key)
            candidates.append(
                RunCandidate(
                    gameKey: key,
                    lastSuccessAt: clock?.lastSuccessAt,
                    lastPlayedAt: game.lastPlayedAt,
                    pendingBytes: input.plan.changedBytes))
        }
        return RunOrdering.order(candidates, now: now).compactMap { byKey[$0.gameKey] }
    }

    // MARK: - Staging and hashing

    func stagingRoute(
        for members: [BackupSetMember], freeSpaceBytes: Int64
    ) -> StagingRoute {
        let saves = members.filter(SaveMemberRule.isSaveMember)
        return StagingBudget.route(
            saveMembersBytes: saves.reduce(0) { $0 + $1.size },
            largestMemberBytes: members.map(\.size).max() ?? 0,
            freeSpaceBytes: freeSpaceBytes)
    }

    /// One member, ready to hash and upload.
    struct StagedMember {
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
    func stage(
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

    struct UploadedBlob {
        var hash: String
        var compression: BlobCompression
        var bytes: Int64
        var path: String
        var isPending: Bool
        /// The put read the file itself, so a write during the put
        /// can reach the blob.
        var readTheFile: Bool
    }

    /// Compresses one blob at a time into the outbox and puts it,
    /// per rule 5 of 6.4 and step 2 of 5.8.
    func uploadBlob(
        _ context: RunContext, file: URL, hash: String
    ) async throws -> UploadedBlob {
        let size = BackupSetResolver.stamp(of: file, fm: fm)?.size ?? 0

        var hash = hash
        var source = file
        var compression = BlobCompression.stored
        var outbox: URL?
        if size <= Self.compressionSizeLimit, let data = try? Data(contentsOf: file) {
            // A save can change between its hash and this read, so
            // the blob takes the hash of the bytes that go up.
            hash = ContentHash.hex(of: data)
            let encoded = BlobCodec.encode(data)
            let url = BackupRootLayout(root: localRoot).outbox.appendingPathComponent(hash)
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.bytes.write(to: url, options: .atomic)
            source = url
            outbox = url
            compression = encoded.algorithm
        }
        defer { if let outbox { try? fm.removeItem(at: outbox) } }
        let path = context.paths.blobPath(hash: hash, fanOutWidth: context.fanOutWidth)

        let uploaded = BackupSetResolver.stamp(of: source, fm: fm)?.size ?? size
        try await claimRoom(context, bytes: uploaded)
        try await put(fileAt: source, to: path, context: context)
        let confirmation = (try? await provider.confirm(path: path)) ?? .pending
        return UploadedBlob(
            hash: hash, compression: compression, bytes: uploaded, path: path,
            isPending: confirmation == .pending, readTheFile: outbox == nil)
    }

    /// Waits for the puts that came back pending, per 8.5.
    ///
    /// iCloud Drive commits and reports the object durable later.
    /// The manifest may not name a blob the remote has not confirmed,
    /// per 5.8, so a blob that stays pending ends the stream without
    /// a manifest. The next run puts the blob again.
    func waitForConfirmations(_ paths: [String]) async throws -> Bool {
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

    func markAttempt(targetId: String, gameKey: String) throws {
        var clock =
            (try? store.staleness(targetId: targetId, gameKey: gameKey))
            ?? StalenessClock(targetId: targetId, gameKey: gameKey)
        clock.lastAttemptAt = now
        try store.saveStaleness(clock)
    }

    /// A snapshot that carries a partial path resets the clock only
    /// when no partial path is a save member, per 7.2.
    func markSuccess(
        targetId: String, gameKey: String, manifest: SnapshotManifest, scannedAt: Date,
        isComplete: Bool
    ) {
        var clock =
            (try? store.staleness(targetId: targetId, gameKey: gameKey))
            ?? StalenessClock(targetId: targetId, gameKey: gameKey)
        clock.lastAttemptAt = now

        let savePartials = PartialPathClock.savePartials(in: manifest.entries)
        if savePartials.isEmpty, isComplete {
            clock.lastSuccessAt = scannedAt
            clock.partialSince = nil
        } else if clock.partialSince == nil {
            clock.partialSince = now
        }
        save(try store.saveStaleness(clock), "the staleness clock of \(gameKey)")

        let previous = (try? store.partialTally(targetId: targetId, gameKey: gameKey)) ?? [:]
        save(
            try store.savePartialTally(
                PartialPathClock.tally(previous, savePartials: savePartials),
                targetId: targetId, gameKey: gameKey),
            "the partial tally of \(gameKey)")
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
        defer { try? fm.removeItem(at: scratch) }
        return try Data(contentsOf: scratch)
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
        fileAt file: URL, to path: String, context: RunContext
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

    /// Reads the space again once the uploads are in, so the row the
    /// detail screen shows counts them.
    func readTheSpaceLeft(_ context: RunContext) async throws {
        guard provider.capabilities.canQueryQuota, context.uploadedBytes > 0 else { return }
        if let fresh = try? await provider.quota() {
            context.quota = fresh
        }
    }

    /// A blob that does not fit under the provider quota or the cap.
    /// It stops its own game only.
    struct NoRoom: Error {
        let blobBytes: Int64
        let freeBytes: Int64
    }

    /// Takes the room for one blob out of what the target has left.
    func claimRoom(_ context: RunContext, bytes: Int64) async throws {
        if !context.hasReadTheRoom {
            if provider.capabilities.canQueryQuota, context.quota == nil {
                context.quota = try? await provider.quota()
            }
            context.room = QuotaCheck.freeBytes(
                reading: context.quota,
                capBytes: context.request.descriptor.capBytes,
                storedBytes: storedBytes(targetId: context.request.descriptor.id))
            context.hasReadTheRoom = true
        }
        guard let room = context.room else { return }
        guard bytes <= room else { throw NoRoom(blobBytes: bytes, freeBytes: room) }
        context.room = room - bytes
    }

    /// What Empo holds on the target now, the number the cap of 5.14
    /// counts. A state store that cannot answer counts nothing, as
    /// the target screen does.
    func storedBytes(targetId: String) -> Int64 {
        ((try? store.usage(targetId: targetId)) ?? []).reduce(0) { $0 + $1.bytes }
    }

    /// The one effect of 8.4, as a run stop. A transient error keeps
    /// the run's own error, and the caller decides.
    func mapped(_ error: BackupProviderError) -> Error {
        switch error {
        case .authExpired:
            return BackupRunStop.needsSignIn
        case .permissionDenied:
            // `run` names the fix, because only the request knows the service.
            return error
        case .rejected(let message):
            return BackupRunStop.rejected(message: message)
        case .offline:
            return BackupRunStop.offline
        case .serverError(let status):
            return BackupRunStop.serverError(status: status)
        case .throttled(let retryAfter):
            return BackupRunStop.throttled(retryAfter: retryAfter)
        case .outOfSpace:
            return BackupRunStop.full(reason: QuotaCheck.prunedAndStillFullLine)
        case .notFound:
            return BackupRunStop.rejected(
                message: "A backup file is missing from this location. Back up again to replace it.")
        }
    }

    func scratchFile() -> URL {
        let url = BackupRootLayout(root: localRoot).outbox
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
