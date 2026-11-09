import Foundation

/// The engine that puts a snapshot back on this device, per SPEC 11.
///
/// It talks to the provider protocol of section 8 alone and never
/// branches on a provider name, the way `SnapshotEngine` does. The
/// rules it applies are pure and live in GameProbe: `RestorePlanner`
/// decides the writes, `RestoreSpaceCheck` refuses a restore that
/// does not fit, and `ProvenCoverage` gates the one place bytes leave
/// the container.
///
/// The order is the design:
///
/// 1. Read the manifest and plan against the local tree.
/// 2. Refuse on the space check of 11.8, before any write.
/// 3. Write the intent record of 6.5, before the first byte lands.
/// 4. Stage and check each blob under `restore/<hash>`, then write
///    the files.
/// 5. Write the finished mark under `restore/`.
/// 6. Drop from a replaced tree only what proven coverage allows.
/// 7. Clear the intent record, then the mark.
///
/// A restore that stops between steps 3 and 5 leaves the record and
/// the staged blobs, so the next launch asks once and a resume skips
/// the blobs it already has.
///
/// Nothing here deletes local data to make room. That is invariant
/// 1's restore twin.
public actor RestoreEngine {

    private let provider: any BackupProvider
    private let store: BackupStateStore
    private let localRoot: URL
    private let fm = FileManager.default
    private let readClock: @Sendable () -> Date

    public init(
        provider: any BackupProvider,
        store: sending BackupStateStore,
        localRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.store = store
        self.localRoot = localRoot
        self.readClock = now
    }

    private var now: Date { readClock() }

    // MARK: - One restore

    public func run(_ request: RestoreRequest) async -> RestoreOutcome {
        let paths = BackupNamespacePaths(
            root: request.root, namespaceId: request.namespaceId)

        let fanOutWidth: Int
        let manifest: SnapshotManifest
        do {
            fanOutWidth =
                try await fetch(paths.formatFile)
                .map { try FormatDescriptor.decode(json: $0).fanOutWidth }
                ?? FormatDescriptor.version1FanOutWidth
            let path = paths.manifestPath(
                stream: request.stream, snapshotId: request.snapshotId)
            guard let data = try await fetch(path),
                let read = try? SnapshotManifest.decode(compressed: data)
            else {
                return .failed(RestoreNotices.unreadableLine)
            }
            manifest = read
        } catch {
            return .failed(Self.line(of: error))
        }
        // The manifest comes from the storage service. A path that
        // leaves its root, or names the root itself, would write
        // outside the game.
        guard manifest.entries.allSatisfy({ RelativePath.staysUnderItsRoot($0.path) }),
            manifest.sharedDataDirectory.map(ExternalMembers.staysInSharedData) ?? true
        else {
            return .failed(RestoreNotices.unreadableLine)
        }

        let tree = request.choice == .replaceTheTree ? request.gameTreeURL : nil
        let replaced = tree.flatMap { treeAside(of: $0, resumingInto: request.movedAsideTree) }
        // A resume finds the tree already aside, and the game may have
        // written new saves into the half-restored `Game/` since the
        // stop. The plan must see them, so the writes move them aside.
        let movesTheTree = replaced.map { !fm.fileExists(atPath: $0.path) } ?? false
        let plan = RestorePlanner.plan(
            manifest: manifest,
            scope: request.choice.scope,
            localFiles: movesTheTree ? request.localFilesOutsideTheTree : request.localFiles,
            localVersionMarker: request.localVersionMarker,
            stagedBlobHashes: stagedBlobHashes())

        if let shortfall = RestoreSpaceCheck.shortfall(
            plan: plan, freeSpaceBytes: request.freeSpaceBytes)
        {
            return .notEnoughSpace(shortfall)
        }

        return await write(
            plan, manifest: manifest, request: request, paths: paths,
            fanOutWidth: fanOutWidth, tree: movesTheTree ? tree : nil, replaced: replaced)
    }

    // MARK: - The writes

    private func write(
        _ plan: RestorePlan,
        manifest: SnapshotManifest,
        request: RestoreRequest,
        paths: BackupNamespacePaths,
        fanOutWidth: Int,
        tree: URL?,
        replaced: URL?
    ) async -> RestoreOutcome {
        let gameKey = request.stream == .preferences ? nil : request.stream.key
        var result = RestoreResult(partialPathCount: plan.partialPaths.count)

        // Without the record, a process that dies mid-restore leaves a
        // silent mix of old and restored files, per 6.5.
        let layout = BackupRootLayout(root: localRoot)
        let resumes: Bool
        do {
            let earlier = try RestoreResumeQuestion.unfinishedRecord(
                in: store, layout: layout, fm: fm)
            resumes =
                earlier?.targetId == request.targetId && earlier?.gameKey == gameKey
                && earlier?.snapshotId == request.snapshotId
            // The mark is still there only when the record of a finished
            // restore did not clear. A new record would leave that one unmarked.
            guard !fm.fileExists(atPath: layout.finishedRestoreMark.path) else {
                return .failed(RestoreNotices.recordsUnavailableLine)
            }
            try store.saveIntent(
                RestoreResumeQuestion.record(
                    targetId: request.targetId,
                    gameKey: gameKey,
                    snapshotId: request.snapshotId,
                    choice: request.choice,
                    movedAsideTree: replaced?.lastPathComponent,
                    at: now))
        } catch {
            return .failed(RestoreNotices.recordsUnavailableLine)
        }

        var staged: Set<String> = []
        for step in plan.steps where step.action != .unchanged && !staged.contains(step.entry.hash) {
            guard !Task.isCancelled else { return .stopped(.gameLaunched, result) }
            do {
                try await stageBlob(step.entry, paths: paths, fanOutWidth: fanOutWidth)
                staged.insert(step.entry.hash)
            } catch BackupProviderError.rejected(let message) {
                if !resumes {
                    try? store.clearIntent(kind: .interruptedRestore)
                    clearStagedBlobs()
                }
                return .failed(message)
            } catch let stop as RestoreStopReason {
                return .stopped(stop, result)
            } catch {
                return .stopped(Task.isCancelled ? .gameLaunched : .targetFailed, result)
            }
        }

        if let tree, let replaced {
            guard (try? fm.moveItem(at: tree, to: replaced)) != nil else {
                try? store.clearIntent(kind: .interruptedRestore)
                return .failed(
                    screenText("Empo couldn't move the current game files aside. Nothing changed."))
            }
        }
        result.replacedTreeName = replaced?.lastPathComponent

        for step in plan.steps {
            guard !Task.isCancelled else {
                // Launching a game stops an in-flight restore at
                // once, per 7.6. Everything already written stays.
                return .stopped(.gameLaunched, result)
            }
            guard step.action != .unchanged else {
                result.unchangedFileCount += 1
                continue
            }
            do {
                try write(step, request: request)
            } catch let stop as RestoreStopReason {
                return .stopped(stop, result)
            } catch {
                return .stopped(Task.isCancelled ? .gameLaunched : .targetFailed, result)
            }
            result.writtenFileCount += 1
            result.bytesWritten += step.entry.size
            if case .writeAfterDisplacing = step.action { result.displacedFileCount += 1 }
        }

        // The mark goes down before the cleanup and before the record
        // clears, so a stop after the last file never asks to resume.
        try? fm.createDirectory(at: layout.restore, withIntermediateDirectories: true)
        try? Data().write(to: layout.finishedRestoreMark)

        if let replaced {
            let decision = dropFromTheReplacedTree(
                replaced, mode: request.mode, snapshot: manifest)
            result.droppedFromReplacedTree = decision.drop.count
            result.replacedTreeKeptBytes = decision.keptBytes
            if removeIfEmpty(replaced) {
                result.replacedTreeName = nil
            }
        }

        if (try? store.clearIntent(kind: .interruptedRestore)) != nil {
            try? fm.removeItem(at: layout.finishedRestoreMark)
        }
        clearStagedBlobs()
        return .finished(result)
    }

    /// The local file moves aside first, and the restored file takes
    /// the real name, per 11.1.
    private func write(_ step: RestoreStep, request: RestoreRequest) throws {
        let entry = step.entry
        let staged = BackupRootLayout(root: localRoot).restoreBlob(hash: entry.hash)
        guard let destination = request.destination.url(of: entry) else {
            throw RestoreStopReason.targetFailed
        }
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
            try fm.moveItem(
                at: destination,
                to: try displacedURL(of: destination, step: step, destination: request.destination))
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch entry.compression {
        case .stored:
            // The staged file is the content, so it copies straight
            // over and never enters memory.
            try fm.copyItem(at: staged, to: destination)
        case .zlib:
            // A compressed blob is under the 32 MB limit of 6.4, so
            // one of them in memory is the peak cost.
            guard let bytes = RestoreStaging.zlibBytes(at: staged, entry: entry) else {
                throw BlobCodec.Failure.corruptZlibStream
            }
            try BlobCodec.decode(
                bytes, algorithm: .zlib, maxBytes: RestoreStaging.inflatedSizeLimit(of: entry)
            )
            .write(to: destination, options: .atomic)
        }
    }

    /// Downloads one blob into `restore/<hash>`, or takes the one
    /// already there.
    ///
    /// A restarted run re-verifies a staged blob and skips it for
    /// free, per 11.9. A staged file whose content does not hash to
    /// its name is thrown away and fetched again.
    private func stageBlob(
        _ entry: SnapshotManifest.Entry, paths: BackupNamespacePaths, fanOutWidth: Int
    ) async throws {
        let staged = BackupRootLayout(root: localRoot).restoreBlob(hash: entry.hash)
        if fm.fileExists(atPath: staged.path) {
            if verify(staged, entry: entry) { return }
            try? fm.removeItem(at: staged)
        }

        try fm.createDirectory(
            at: BackupRootLayout(root: localRoot).restore, withIntermediateDirectories: true)
        let path = paths.blobPath(hash: entry.hash, fanOutWidth: fanOutWidth)
        do {
            try await provider.get(path: path, localFile: staged)
        } catch {
            try? fm.removeItem(at: staged)
            if case .rejected = error { throw error }
            // The cancel of 7.6 usually lands while the download is
            // in flight, and the session reports it as a transport
            // error. The cancel flag says what really happened.
            throw Task.isCancelled ? RestoreStopReason.gameLaunched : Self.stop(of: error)
        }
        guard verify(staged, entry: entry) else {
            try? fm.removeItem(at: staged)
            throw RestoreStopReason.targetFailed
        }
    }

    /// The plan names the displaced copy. A file the plan did not see,
    /// such as a save the game wrote after the plan, takes the next
    /// free name, so no local file is ever deleted.
    private func displacedURL(
        of destination: URL, step: RestoreStep, destination roots: MemberSource
    ) throws -> URL {
        if case .writeAfterDisplacing(let path) = step.action {
            guard let url = roots.url(root: step.entry.root, path: path) else {
                throw RestoreStopReason.targetFailed
            }
            return url
        }
        let folder = destination.deletingLastPathComponent()
        let taken = Set(try fm.contentsOfDirectory(atPath: folder.path))
        return folder.appendingPathComponent(
            DisplacedCopy.nextFileName(for: destination.lastPathComponent, taken: taken))
    }

    /// Whether a staged file holds the entry's bytes.
    ///
    /// A stored blob hashes from disk, so a 4 GB game asset never
    /// enters memory. `RestoreStaging.holds` answers the other case.
    private func verify(_ file: URL, entry: SnapshotManifest.Entry) -> Bool {
        switch entry.compression {
        case .stored:
            return (try? ContentHash.hexOfFile(at: file)) == entry.hash
        case .zlib:
            guard let bytes = RestoreStaging.zlibBytes(at: file, entry: entry) else { return false }
            return RestoreStaging.holds(bytes, entry: entry)
        }
    }

    // MARK: - The replace path, per 11.12

    /// Where `Game/` goes aside, or `nil` when there is nothing to
    /// move. A resume keeps the folder its first try named. That
    /// folder may not exist yet, when the process died between the
    /// record and the move.
    private func treeAside(of tree: URL, resumingInto earlier: String?) -> URL? {
        let parent = tree.deletingLastPathComponent()
        if let earlier {
            let url = parent.appendingPathComponent(earlier, isDirectory: true)
            return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: tree.path) ? url : nil
        }
        guard fm.fileExists(atPath: tree.path) else { return nil }
        let taken = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
        let name = DisplacedCopy.nextTreeName(for: tree.lastPathComponent, taken: taken)
        return parent.appendingPathComponent(name, isDirectory: true)
    }

    /// Drops from the replaced tree only the files with proven
    /// coverage, per 11.12.
    ///
    /// The snapshot handed in is the one this restore just read, so
    /// it is readable at this moment by construction. The save
    /// classifier never reaches this decision.
    private func dropFromTheReplacedTree(
        _ tree: URL, mode: BackupMode, snapshot: SnapshotManifest
    ) -> ProvenCoverage.Decision {
        var files: [ProvenCoverage.TreeFile] = []
        for file in BackupSetResolver.files(under: tree, fm: fm) {
            let url = tree.appendingPathComponent(file.path)
            guard let hash = try? ContentHash.hexOfFile(at: url) else { continue }
            files.append(
                ProvenCoverage.TreeFile(path: file.path, hash: hash, sizeBytes: file.size))
        }

        let decision = ProvenCoverage.decide(
            mode: mode, treeFiles: files, readableSnapshot: snapshot)
        for path in decision.drop {
            try? fm.removeItem(at: tree.appendingPathComponent(path))
        }
        return decision
    }

    /// A link, or a file the walk could not list or hash, keeps its
    /// folder, per 11.12.
    private func removeIfEmpty(_ folder: URL) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        var left = names.count
        for name in names {
            let child = folder.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true, removeIfEmpty(child) {
                left -= 1
            }
        }
        guard left == 0 else { return false }
        return (try? fm.removeItem(at: folder)) != nil
    }

    // MARK: - Staged blobs

    /// The blobs already under `restore/`. A cancel keeps them, so
    /// this is what a resume skips.
    private func stagedBlobHashes() -> Set<String> {
        let directory = BackupRootLayout(root: localRoot).restore
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(Self.scratchPrefix) })
    }

    /// Empties `restore/` once a restore finishes. One restore runs
    /// at a time, so every staged blob there is this one's, or one
    /// an earlier stopped run left behind and this run did not need.
    private func clearStagedBlobs() {
        let directory = BackupRootLayout(root: localRoot).restore
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where !name.hasPrefix(Self.scratchPrefix) && name != BackupRootLayout.finishedRestoreMarkName {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - The provider

    /// The prefix of a scratch read under `restore/`. A blob there
    /// is named by its hash, so this prefix keeps the two apart.
    private static let scratchPrefix = "read-"

    private func fetch(_ path: String) async throws -> Data? {
        let scratch = BackupRootLayout(root: localRoot).restore
            .appendingPathComponent(Self.scratchPrefix + UUID().uuidString)
        try? fm.createDirectory(
            at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await provider.get(path: path, localFile: scratch)
        } catch {
            try? fm.removeItem(at: scratch)
            if error == .notFound { return nil }
            throw error
        }
        defer { try? fm.removeItem(at: scratch) }
        return try Data(contentsOf: scratch)
    }

    private static func stop(of error: BackupProviderError) -> RestoreStopReason {
        switch error {
        case .outOfSpace:
            return .outOfSpace
        case .authExpired, .throttled, .offline, .serverError, .permissionDenied, .notFound, .rejected:
            return .targetFailed
        }
    }

    private static func line(of error: Error) -> String {
        guard let providerError = error as? BackupProviderError,
            case .rejected(let message) = providerError
        else { return RestoreNotices.unreadableLine }
        return message
    }
}
