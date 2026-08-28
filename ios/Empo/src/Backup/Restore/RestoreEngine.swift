import Foundation
import GameProbe

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
/// 4. Stage each blob under `restore/<hash>` and write its file.
/// 5. Drop from a replaced tree only what proven coverage allows.
/// 6. Clear the intent record.
///
/// A restore that stops between steps 3 and 6 leaves the record and
/// the staged blobs, so the next launch asks once and a resume skips
/// the blobs it already has.
///
/// Nothing here deletes local data to make room. That is invariant
/// 1's restore twin.
actor RestoreEngine {

    private let provider: any BackupProvider
    private let store: BackupStateStore
    private let localRoot: URL
    private let fm = FileManager.default
    private let readClock: @Sendable () -> Date

    init(
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

    func run(_ request: RestoreRequest) async -> RestoreOutcome {
        let paths = BackupNamespacePaths(
            root: request.descriptor.root, namespaceId: request.namespaceId)

        var fanOutWidth = FormatDescriptor.version1FanOutWidth
        if let data = try? await fetch(paths.formatFile),
            let descriptor = try? FormatDescriptor.decode(json: data)
        {
            fanOutWidth = descriptor.fanOutWidth
        }

        let manifest: SnapshotManifest
        do {
            let path = paths.manifestPath(
                stream: request.stream, snapshotId: request.snapshotId)
            guard let data = try await fetch(path),
                let read = try? SnapshotManifest.decode(compressed: data)
            else {
                return .failed(Self.unreadableLine)
            }
            manifest = read
        } catch {
            return .failed(Self.line(of: error))
        }

        let plan = RestorePlanner.plan(
            manifest: manifest,
            scope: request.scope,
            localFiles: request.localFiles,
            localVersionMarker: request.localVersionMarker,
            stagedBlobHashes: stagedBlobHashes())

        if let shortfall = RestoreSpaceCheck.shortfall(
            plan: plan, freeSpaceBytes: request.freeSpaceBytes)
        {
            return .notEnoughSpace(shortfall)
        }

        return await write(
            plan, manifest: manifest, request: request, paths: paths,
            fanOutWidth: fanOutWidth)
    }

    // MARK: - The writes

    private func write(
        _ plan: RestorePlan,
        manifest: SnapshotManifest,
        request: RestoreRequest,
        paths: BackupNamespacePaths,
        fanOutWidth: Int
    ) async -> RestoreOutcome {
        // The record goes in before the first byte lands, so a
        // process that dies mid-restore leaves one, per 6.5.
        try? store.saveIntent(
            RestoreResumeQuestion.record(
                targetId: request.descriptor.id,
                gameKey: request.stream == .preferences ? nil : request.stream.key,
                snapshotId: request.snapshotId,
                at: now))

        var result = RestoreResult(partialPathCount: plan.partialPaths.count)
        var replaced: URL?
        if request.replacesTheTree, let tree = request.gameTreeURL {
            do {
                replaced = try moveTheTreeAside(tree)
                result.replacedTreeName = replaced?.lastPathComponent
            } catch {
                return .failed("the game files could not be moved aside")
            }
        }

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
                try await write(step, request: request, paths: paths, fanOutWidth: fanOutWidth)
            } catch let stop as RestoreStopReason {
                return .stopped(stop, result)
            } catch {
                return .stopped(.targetFailed, result)
            }
            result.writtenFileCount += 1
            result.bytesWritten += step.entry.size
            if case .writeAfterDisplacing = step.action { result.displacedFileCount += 1 }
        }

        if let replaced {
            let decision = dropFromTheReplacedTree(
                replaced, mode: request.mode, snapshot: manifest)
            result.droppedFromReplacedTree = decision.drop.count
            result.replacedTreeKeptBytes = decision.keptBytes
            if decision.clearsItself {
                // The whole tree was provably covered, so it clears
                // itself and leaves nothing for the user to sweep
                // up, per 11.12.
                try? fm.removeItem(at: replaced)
                result.replacedTreeName = nil
            }
        }

        try? store.clearIntent(kind: .interruptedRestore)
        clearStagedBlobs(plan.blobs)
        return .finished(result)
    }

    /// Stages one blob and writes its file.
    ///
    /// The local file moves aside first, and the restored file takes
    /// the real name, per 11.1. Nothing is deleted.
    private func write(
        _ step: RestoreStep,
        request: RestoreRequest,
        paths: BackupNamespacePaths,
        fanOutWidth: Int
    ) async throws {
        let entry = step.entry
        guard let destination = request.destination.url(of: entry) else {
            throw RestoreStopReason.targetFailed
        }
        let staged = try await stageBlob(entry, paths: paths, fanOutWidth: fanOutWidth)

        if case .writeAfterDisplacing(let displacedPath) = step.action,
            let displaced = request.destination.url(root: entry.root, path: displacedPath)
        {
            try fm.moveItem(at: destination, to: displaced)
        }

        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)

        switch entry.compression {
        case .stored:
            // The staged file is the content, so it copies straight
            // over and never enters memory.
            try fm.copyItem(at: staged, to: destination)
        case .zlib:
            // A compressed blob is under the 32 MB limit of 6.4, so
            // one of them in memory is the peak cost.
            let bytes = try Data(contentsOf: staged)
            try BlobCodec.decode(bytes, algorithm: .zlib).write(to: destination, options: .atomic)
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
    ) async throws -> URL {
        let staged = BackupRootLayout.restoreBlob(root: localRoot, hash: entry.hash)
        if fm.fileExists(atPath: staged.path) {
            if verify(staged, entry: entry) { return staged }
            try? fm.removeItem(at: staged)
        }

        try fm.createDirectory(
            at: BackupRootLayout.restore(root: localRoot), withIntermediateDirectories: true)
        let path = paths.blobPath(hash: entry.hash, fanOutWidth: fanOutWidth)
        do {
            try await provider.get(path: path, localFile: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw Self.stop(of: error)
        }
        guard verify(staged, entry: entry) else {
            try? fm.removeItem(at: staged)
            throw RestoreStopReason.targetFailed
        }
        return staged
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
            guard let bytes = try? Data(contentsOf: file) else { return false }
            return RestoreStaging.holds(bytes, entry: entry)
        }
    }

    // MARK: - The replace path, per 11.12

    /// Moves `Game/` to a hidden sibling and answers where it went.
    private func moveTheTreeAside(_ tree: URL) throws -> URL? {
        guard fm.fileExists(atPath: tree.path) else { return nil }
        let parent = tree.deletingLastPathComponent()
        let taken = Set(
            (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
        let name = DisplacedCopy.nextTreeName(for: tree.lastPathComponent, taken: taken)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        try fm.moveItem(at: tree, to: destination)
        return destination
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

    // MARK: - Staged blobs

    /// The blobs already under `restore/`. A cancel keeps them, so
    /// this is what a resume skips.
    private func stagedBlobHashes() -> Set<String> {
        let directory = BackupRootLayout.restore(root: localRoot)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(Self.scratchPrefix) })
    }

    /// Clears the blobs a finished restore no longer needs. A
    /// stopped restore keeps them.
    private func clearStagedBlobs(_ blobs: [RestoreBlob]) {
        for blob in blobs {
            try? fm.removeItem(at: BackupRootLayout.restoreBlob(root: localRoot, hash: blob.hash))
        }
    }

    // MARK: - The provider

    /// The prefix of a scratch read under `restore/`. A blob there
    /// is named by its hash, so this prefix keeps the two apart.
    private static let scratchPrefix = "read-"

    private func fetch(_ path: String) async throws -> Data? {
        let scratch = BackupRootLayout.restore(root: localRoot)
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
        let data = try? Data(contentsOf: scratch)
        try? fm.removeItem(at: scratch)
        return data
    }

    private static func stop(of error: BackupProviderError) -> RestoreStopReason {
        switch error {
        case .outOfSpace:
            return .outOfSpace
        case .authExpired, .throttled, .offline, .permissionDenied, .notFound, .rejected:
            return .targetFailed
        }
    }

    private static let unreadableLine = "this backup could not be read"

    private static func line(of error: Error) -> String {
        guard let providerError = error as? BackupProviderError,
            case .rejected(let message) = providerError
        else { return unreadableLine }
        return message
    }
}
