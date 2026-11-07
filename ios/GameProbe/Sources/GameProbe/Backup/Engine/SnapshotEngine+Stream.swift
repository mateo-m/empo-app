import Foundation

extension SnapshotEngine {

    /// One stream, resolved and diffed before the run uploads a byte.
    struct StreamInput {
        let stream: BackupStream
        let source: MemberSource
        let header: SnapshotManifest
        let kind: StreamKind
        let isOneOff: Bool
        let isGame: Bool
        let previous: SnapshotManifest?
        let plan: SnapshotDiff.Plan
        /// When the plan read the files. A play that ends after this
        /// date is not in the snapshot.
        let scannedAt: Date
    }

    /// What one stream carries from its plan to its manifest.
    ///
    /// One object per stream, so the upload of one member reads and
    /// writes the same state the close reads.
    final class StreamRun {

        let stream: BackupStream
        let source: MemberSource
        let header: SnapshotManifest
        let kind: StreamKind
        let isOneOff: Bool
        let previous: SnapshotManifest?
        let plan: SnapshotDiff.Plan
        let route: StagingRoute
        /// Where the copies of rule 1 of 6.4 go.
        let staging: URL
        let snapshotId: String
        /// The sum the plan of 13.2 froze. No later work changes it.
        let plannedBytes: Int64
        let scannedAt: Date

        var result: StreamResult
        var entries: [SnapshotManifest.Entry]
        /// Every blob this stream put on the target, from the
        /// checkpoint of 6.5 and from this run.
        var confirmed: [String: BlobCompression]
        /// The puts that came back pending, per 8.5.
        var pendingPaths: [String] = []
        /// The blobs of `pendingPaths`. The checkpoint leaves them
        /// out, so a later run never names a blob the target did not
        /// confirm.
        var pendingHashes: Set<String> = []
        /// A member the manifest cannot hold. The game keeps its
        /// dirty mark and does not count as backed up.
        var missedMember = false
        var confirmedBytes: Int64 = 0

        var key: String { stream.key }

        init(
            stream: BackupStream,
            source: MemberSource,
            header: SnapshotManifest,
            kind: StreamKind,
            isOneOff: Bool,
            previous: SnapshotManifest?,
            plan: SnapshotDiff.Plan,
            route: StagingRoute,
            staging: URL,
            snapshotId: String,
            scannedAt: Date,
            confirmed: [String: BlobCompression]
        ) {
            self.stream = stream
            self.source = source
            self.header = header
            self.kind = kind
            self.isOneOff = isOneOff
            self.previous = previous
            self.plan = plan
            self.route = route
            self.staging = staging
            self.snapshotId = snapshotId
            self.scannedAt = scannedAt
            self.plannedBytes = plan.changedBytes
            self.result = StreamResult(streamKey: stream.key, outcome: .blobsOnly)
            self.entries = plan.reused
            self.confirmed = confirmed
        }
    }

    // MARK: - One stream

    func runStream(_ context: RunContext, _ input: StreamInput) async throws {
        await observer?.runStages(streamKey: input.stream.key)
        guard let run = try await decide(context, input) else { return }
        await observer?.runUploads(streamKey: input.stream.key)

        try? fm.createDirectory(at: run.staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: run.staging) }

        for (index, member) in run.plan.changed.enumerated() {
            // The file boundary of 7.6: a pause leaves whole files
            // behind, and the checkpoint carries the rest.
            guard !Task.isCancelled else { throw BackupRunStop.paused }
            // A game that starts mid-stream writes the files this
            // stream still has to read.
            if input.isGame, await !(observer?.runMayGoOn() ?? true) {
                throw BackupRunStop.gameStarted
            }
            do {
                try await upload(member, at: index, of: run, in: context)
            } catch let noRoom as NoRoom {
                let rest = run.plan.changed.dropFirst(index + 1).reduce(0) { $0 + $1.size }
                skipForRoom(run, noRoom, neededBytes: noRoom.blobBytes + rest, in: context)
                return
            }
        }
        context.uploadedBytes += run.result.uploadedBytes
        try await close(run, in: context)
    }

    /// The checkpoint keeps the blobs that went up, so the next run
    /// reuses them once the target has room.
    private func skipForRoom(
        _ run: StreamRun, _ noRoom: NoRoom, neededBytes: Int64, in context: RunContext
    ) {
        let missing = QuotaCheck.Shortfall(neededBytes: neededBytes, freeBytes: noRoom.freeBytes)
        context.uploadedBytes += run.result.uploadedBytes
        run.result.outcome = .failed(reason: QuotaCheck.blockedLine(missing))
        context.streams.append(run.result)
        try? markAttempt(targetId: context.request.descriptor.id, gameKey: run.key)
        if let earlier = context.shortfall {
            context.shortfall = QuotaCheck.Shortfall(
                neededBytes: earlier.neededBytes + missing.missingBytes,
                freeBytes: earlier.freeBytes)
        } else {
            context.shortfall = missing
        }
    }

    /// Everything the stream reads before it moves a byte, or `nil`
    /// where it writes nothing. A stream that stops here records its
    /// own outcome.
    private func decide(_ context: RunContext, _ input: StreamInput) async throws -> StreamRun? {
        let targetId = context.request.descriptor.id
        let stream = input.stream
        let previous = input.previous
        let plan = input.plan

        if let previous, !previous.access.allowsWrite {
            guard case .readOnly(let restriction) = previous.access else { return nil }
            throw BackupRunStop.readOnlyFormat(restriction)
        }

        if plan.changed.isEmpty,
            !input.isOneOff,
            !SnapshotDiff.earnsSnapshot(entries: plan.reused, previous: previous)
        {
            closeWithNoChange(
                context, stream: stream, previous: previous, header: input.header,
                scannedAt: input.scannedAt)
            return nil
        }

        let route = stagingRoute(for: plan.changed, freeSpaceBytes: context.request.freeSpaceBytes)
        guard route != .notEnoughSpace else {
            context.streams.append(
                StreamResult(streamKey: stream.key, outcome: .notEnoughLocalSpace))
            try? markAttempt(targetId: targetId, gameKey: stream.key)
            return nil
        }

        var confirmed: [String: BlobCompression] = [:]
        for blob in (try? store.checkpoint(targetId: targetId, gameKey: stream.key))?
            .confirmedBlobs ?? []
        {
            confirmed[blob.hash] = blob.compression
        }

        return StreamRun(
            stream: stream,
            source: input.source,
            header: input.header,
            kind: input.kind,
            isOneOff: input.isOneOff,
            previous: previous,
            plan: plan,
            route: route,
            staging: BackupRootLayout(root: localRoot).staging
                .appendingPathComponent(stream.key, isDirectory: true),
            snapshotId: BackupKeys.makeSnapshotId(date: now),
            scannedAt: input.scannedAt,
            confirmed: confirmed)
    }

    /// One member: stage it, put the blob where the target holds
    /// none, and write the record a process death leaves behind.
    private func upload(
        _ member: BackupSetMember, at index: Int, of run: StreamRun, in context: RunContext
    ) async throws {
        guard let file = run.source.url(of: member) else {
            run.missedMember = true
            return
        }
        let targetId = context.request.descriptor.id
        let staged = try stage(member, from: file, route: run.route, into: run.staging, index: index)
        var entry = SnapshotManifest.Entry(
            root: member.root,
            path: member.path,
            size: staged.stamp.size,
            modifiedAt: staged.stamp.modifiedAt,
            hash: staged.hash,
            compression: .stored,
            partial: staged.partial,
            detectionSource: member.detectionSource)

        let known =
            run.confirmed[staged.hash]
            ?? run.previous?.entries.first { $0.hash == staged.hash }?.compression

        var readTheFile = false
        if let algorithm = known {
            // The blob is already on the target, so the entry costs
            // nothing. It still has to name the algorithm the blob
            // went up with.
            entry.compression = algorithm
        } else {
            await observer?.runSendsBlob(bytes: member.size)
            let uploaded = try await uploadBlob(context, file: staged.file, hash: staged.hash)
            entry.hash = uploaded.hash
            entry.compression = uploaded.compression
            run.result.uploadedBytes += uploaded.bytes
            run.result.uploadedBlobCount += 1
            run.confirmed[uploaded.hash] = uploaded.compression
            if uploaded.isPending {
                run.pendingPaths.append(uploaded.path)
                run.pendingHashes.insert(uploaded.hash)
            }
            readTheFile = uploaded.readTheFile
        }
        // The plan counts the member, so the progress counts the
        // member as well, whichever of the two paths above put the
        // blob on the target.
        run.confirmedBytes += member.size
        await observer?.runConfirmed(streamKey: run.key, bytes: member.size)

        var kept: SnapshotManifest.Entry? = entry
        if case .inPlace = run.route, SaveMemberRule.isSaveMember(member) {
            // Hash, upload, re-hash, and mark the path partial on a
            // mismatch.
            let after = try? ContentHash.hexOfFile(at: staged.file)
            if after != staged.hash {
                entry.partial = true
                kept = entry
                if readTheFile {
                    // The blob can hold bytes from two moments under
                    // one hash. The entry keeps the last snapshot's
                    // bytes, and the sweep takes the blob.
                    run.confirmed[entry.hash] = nil
                    kept = run.previous?.entries
                        .first { $0.root == member.root && $0.path == member.path }
                    kept?.partial = true
                }
            }
        }

        if entry.partial { run.result.partialPaths.append(member.path) }
        if let kept { run.entries.append(kept) } else { run.missedMember = true }
        save(
            try store.saveCheckpoint(
                RunCheckpoint(
                    targetId: targetId,
                    gameKey: run.key,
                    snapshotId: run.snapshotId,
                    uploadedBytes: run.result.uploadedBytes,
                    pendingPaths: run.plan.changed.dropFirst(index + 1).map(\.path),
                    confirmedBlobs: run.confirmed
                        .filter { !run.pendingHashes.contains($0.key) }
                        .map { ConfirmedBlob(hash: $0.key, compression: $0.value) }
                        .sorted { $0.hash < $1.hash },
                    updatedAt: now)),
            "the checkpoint of \(run.key)")
        // The record a process death leaves behind, per 6.5. The run
        // clears it at its end, so only a death keeps it. The bytes
        // are what the target holds of the plan, across every attempt,
        // so a resumed run killed past the floor asks like a first one.
        save(
            try store.saveIntent(
                BackupIntentRecord(
                    kind: .interruptedRun,
                    targetId: targetId,
                    gameKey: run.key,
                    snapshotId: run.snapshotId,
                    uploadedBytes: run.confirmedBytes,
                    remainingBytes: max(0, run.plannedBytes - run.confirmedBytes),
                    createdAt: now)),
            "the interrupted-run record of \(run.key)")
    }

    /// Step 3 of 5.8: the manifest goes last, after the target
    /// confirms every blob it names.
    private func close(_ run: StreamRun, in context: RunContext) async throws {
        let targetId = context.request.descriptor.id

        // Content decides, per 7.7. The filter of the diff reads
        // size and mtime, so a file whose bytes never moved can
        // still reach the hash. The entry set is the test, and a run
        // that matches the last one writes no snapshot.
        guard run.isOneOff || SnapshotDiff.earnsSnapshot(entries: run.entries, previous: run.previous)
        else {
            closeWithNoChange(
                context, stream: run.stream, previous: run.previous, header: run.header,
                scannedAt: run.scannedAt, isComplete: !run.missedMember)
            return
        }

        // A blob still pending leaves the manifest for the next run.
        guard try await waitForConfirmations(run.pendingPaths) else {
            context.streams.append(run.result)
            try? markAttempt(targetId: targetId, gameKey: run.key)
            return
        }

        var manifest = run.header
        manifest.entries = run.entries.sorted {
            $0.root == $1.root ? $0.path < $1.path : $0.root.rawValue < $1.root.rawValue
        }
        try await put(
            try manifest.compressedData(),
            to: context.paths.manifestPath(stream: run.stream, snapshotId: run.snapshotId))

        save(
            try store.recordUploadedManifest(
                manifest, snapshotId: run.snapshotId, targetId: targetId, uploadedAt: now),
            "the manifest record of \(run.key)")
        save(
            try store.recordSnapshot(
                SnapshotLedgerEntry(
                    targetId: targetId, gameKey: run.key, snapshotId: run.snapshotId,
                    createdAt: now, isOneOff: run.isOneOff)),
            "the snapshot ledger row of \(run.key)")
        save(
            try store.clearCheckpoint(targetId: targetId, gameKey: run.key),
            "the end of the checkpoint of \(run.key)")
        if !run.missedMember {
            save(
                try store.clearDirty(
                    targetId: targetId, gameKey: run.key, markedUpTo: run.scannedAt),
                "the end of the dirty mark of \(run.key)")
        }
        markSuccess(
            targetId: targetId, gameKey: run.key, manifest: manifest, scannedAt: run.scannedAt,
            isComplete: !run.missedMember)

        run.result.outcome = .wroteSnapshot(snapshotId: run.snapshotId)
        // Step 4 of 5.8, inline at the end of the stream that just
        // closed, per 5.10.
        run.result.prunedSnapshotIds = await prune(
            context, stream: run.stream, kind: run.kind,
            preset: context.request.retentionPreset)
        context.streams.append(run.result)
    }

    /// The last manifest already holds the files the run read, so the
    /// game counts as backed up at the time of the read.
    private func closeWithNoChange(
        _ context: RunContext, stream: BackupStream, previous: SnapshotManifest?,
        header: SnapshotManifest, scannedAt: Date, isComplete: Bool = true
    ) {
        let targetId = context.request.descriptor.id
        context.streams.append(StreamResult(streamKey: stream.key, outcome: .noChange))
        save(
            try store.clearCheckpoint(targetId: targetId, gameKey: stream.key),
            "the end of the checkpoint of \(stream.key)")
        if isComplete {
            save(
                try store.clearDirty(
                    targetId: targetId, gameKey: stream.key, markedUpTo: scannedAt),
                "the end of the dirty mark of \(stream.key)")
        }
        markSuccess(
            targetId: targetId, gameKey: stream.key, manifest: previous ?? header,
            scannedAt: scannedAt, isComplete: isComplete)
    }
}
