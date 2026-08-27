import Foundation
import GameProbe

/// The iCloud Drive target of SPEC 9.1, the first real provider.
///
/// Foundation only. No SDK, no login screen, and no account to
/// configure: the signed-in Apple ID is the account. It meets the six
/// operations of 8.1 and nothing else, and the engine never learns
/// which provider it holds.
///
/// The transfer rides the system daemon, outside the app's lifetime,
/// so no background URLSession is involved here. What the app owns is
/// the local write, and 8.2 asks that write to be atomic.
///
/// The rules a test can reach live in `ICloudDrive`, inside GameProbe.
/// This file needs a real ubiquity container.
actor ICloudDriveTarget: BackupProvider {

    nonisolated let capabilities = ICloudDrive.capabilities

    /// How long a `get` waits for the daemon to bring an item down
    /// before it leaves the work for the next pass.
    private static let downloadWait: TimeInterval = 60
    private static let downloadPollWait: TimeInterval = 0.5

    /// The ubiquity container. Every path a caller gives already
    /// carries the fixed root of 8.7, because the engine builds it in
    /// through `BackupNamespacePaths` and the permission check builds
    /// it in through `makeProbePath(root:)`. A second prefix here
    /// would write `Documents/Empo Backups` twice.
    private let root: URL
    private let watch: ICloudUploadWatch
    private let gate = TransferGate()

    init(containerURL: URL, watch: ICloudUploadWatch) {
        self.root = containerURL
        self.watch = watch
    }

    // MARK: - The six operations

    func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        let root = self.root
        return try await gate.request { () async throws(BackupProviderError) -> [RemoteObject] in
            try await Self.offTheCooperativePool {
                Self.objects(under: root, prefix: prefix)
            }
        }
    }

    func put(localFile: URL, path: String) async throws(BackupProviderError) {
        // Before any byte moves, per 8.3. iCloud states no number,
        // so this rejects nothing today and stays for the day the
        // spec gives it one.
        let size = Self.fileSize(at: localFile)
        if let rejection = capabilities.rejection(forFileOfSize: size) { throw rejection }

        let destination = fileURL(forPath: path)
        try await gate.transfer { () async throws(BackupProviderError) in
            try await Self.offTheCooperativePool {
                Self.write(localFile: localFile, to: destination)
            }
        }
    }

    /// Whether the daemon has the object, per 8.5.
    ///
    /// The local write returned long before this, so `pending` is the
    /// normal first answer. The engine re-reads it, and a blob still
    /// pending leaves the manifest for the next run, per 5.8.
    func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        let url = fileURL(forPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupProviderError.notFound
        }
        guard let reading = await watch.reading(for: url) else {
            // The file is on disk and the query has not caught up
            // with it. Nothing is durable yet.
            return .pending
        }
        if let error = reading.uploadingError { throw error }
        return reading.isUploaded ? .confirmed : .pending
    }

    func get(path: String, localFile: URL) async throws(BackupProviderError) {
        let source = fileURL(forPath: path)
        guard Self.holdsObject(at: source) else { throw BackupProviderError.notFound }
        try await gate.transfer { () async throws(BackupProviderError) in
            try await self.download(source)
            try await Self.offTheCooperativePool {
                Self.read(source, to: localFile)
            }
        }
    }

    func delete(paths: [String]) async throws(BackupProviderError) {
        let urls = paths.map(fileURL(forPath:))
        try await gate.request { () async throws(BackupProviderError) in
            try await Self.offTheCooperativePool {
                Self.remove(urls)
            }
        }
    }

    /// iCloud answers no space query, per 9.7. A full account shows
    /// up as an upload error instead, and 5.14 runs its ladder there.
    func quota() async throws(BackupProviderError) -> QuotaReading? {
        nil
    }

    // MARK: - Paths

    nonisolated func fileURL(forPath path: String) -> URL {
        var url = root
        for part in path.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
        }
        return url
    }

    /// Whether the target holds this object, on this device or in
    /// the daemon.
    ///
    /// A device that never downloaded an object can hold
    /// `.<name>.icloud` in its place, so the real name alone is not
    /// the whole answer. `startDownloadingUbiquitousItem` still
    /// takes the real name.
    private static func holdsObject(at url: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return true }
        return manager.fileExists(atPath: placeholderURL(of: url).path)
    }

    private static func placeholderURL(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    // MARK: - The download wait

    /// Asks the daemon for an item this device does not hold, then
    /// waits for it.
    ///
    /// A wait that runs out is not a failure of the target. The next
    /// pass asks again, per 8.4.
    private func download(_ url: URL) async throws(BackupProviderError) {
        if let reading = await watch.reading(for: url), reading.isDownloaded { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        var left = Self.downloadWait
        while left > 0 {
            if let reading = await watch.reading(for: url) {
                if let error = reading.uploadingError { throw error }
                if reading.isDownloaded { return }
            }
            try? await Task.sleep(for: .seconds(Self.downloadPollWait))
            left -= Self.downloadPollWait
        }
        throw BackupProviderError.offline
    }

    // MARK: - The file work

    /// `NSFileCoordinator` waits on the iCloud daemon, so one call
    /// can hold its thread for seconds. Swift's cooperative pool has
    /// one thread per core and a blocked one starves every other
    /// task, so every coordinated call runs here instead.
    private static let fileQueue = DispatchQueue(
        label: "sh.mateo.empo.backup.icloud", qos: .utility, attributes: .concurrent)

    private static func offTheCooperativePool<T: Sendable>(
        _ body: @escaping @Sendable () -> Result<T, BackupProviderError>
    ) async throws(BackupProviderError) -> T {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<T, BackupProviderError>, Never>) in
            fileQueue.async { continuation.resume(returning: body()) }
        }
        return try result.get()
    }

    /// Copies the file in, then replaces the object in one step.
    ///
    /// The replace needs the new file on the same volume, and the
    /// item replacement directory is the one place the system
    /// promises that. A reader therefore sees the old content or the
    /// complete new content and never a torn write, per 8.2.
    private static func write(
        localFile: URL, to destination: URL
    ) -> Result<Void, BackupProviderError> {
        let manager = FileManager.default
        let scratch: URL
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            scratch = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: destination, create: true)
        } catch {
            return .failure(mapped(error))
        }
        defer { try? manager.removeItem(at: scratch) }

        let staged = scratch.appendingPathComponent(destination.lastPathComponent)
        do {
            try manager.copyItem(at: localFile, to: staged)
        } catch {
            return .failure(mapped(error))
        }

        var failure: BackupProviderError?
        var coordination: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: destination, options: .forReplacing, error: &coordination
        ) { url in
            do {
                if manager.fileExists(atPath: url.path) {
                    _ = try manager.replaceItemAt(url, withItemAt: staged)
                } else {
                    try manager.moveItem(at: staged, to: url)
                }
            } catch {
                failure = mapped(error)
            }
        }
        if let coordination { return .failure(mapped(coordination)) }
        if let failure { return .failure(failure) }
        return .success(())
    }

    private static func read(_ source: URL, to localFile: URL) -> Result<Void, BackupProviderError> {
        let manager = FileManager.default
        var failure: BackupProviderError?
        var coordination: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: [], error: &coordination
        ) { url in
            do {
                try manager.createDirectory(
                    at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: localFile.path) {
                    try manager.removeItem(at: localFile)
                }
                try manager.copyItem(at: url, to: localFile)
            } catch {
                failure = mapped(error)
            }
        }
        if let coordination { return .failure(mapped(coordination)) }
        if let failure { return .failure(failure) }
        return .success(())
    }

    /// A path that holds no object is not an error, per 8.1. The
    /// delete has already got what it asked for.
    private static func remove(_ urls: [URL]) -> Result<Void, BackupProviderError> {
        let manager = FileManager.default
        for url in urls where manager.fileExists(atPath: url.path) {
            var failure: BackupProviderError?
            var coordination: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordination
            ) { target in
                do {
                    try manager.removeItem(at: target)
                } catch {
                    failure = mapped(error)
                }
            }
            if let coordination { return .failure(mapped(coordination)) }
            if let failure { return .failure(failure) }
        }
        return .success(())
    }

    /// Every object under the root whose path starts with `prefix`.
    ///
    /// There is no directory model, per 8.1, so the path a caller
    /// sees is the whole name under the root.
    private static func objects(
        under root: URL, prefix: String
    ) -> Result<[RemoteObject], BackupProviderError> {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(mapped(error))
        }

        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard
            let walker = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                ])
        else {
            return .success([])
        }

        var found: [RemoteObject] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }

            var path = String(full.dropFirst(base.count + 1))
            path = realName(ofPlaceholderPath: path) ?? path
            guard path.hasPrefix(prefix) else { continue }

            found.append(
                RemoteObject(
                    path: path,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate))
        }
        return .success(found.sorted { $0.path < $1.path })
    }

    /// The real name behind an iCloud placeholder, or `nil` when the
    /// path names a real file.
    ///
    /// A device that never downloaded an object can hold
    /// `.<name>.icloud` in its place. The engine asks for objects by
    /// their real name, so the list must answer with that name.
    private static func realName(ofPlaceholderPath path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard var last = parts.popLast(), last.hasPrefix("."), last.hasSuffix(".icloud") else {
            return nil
        }
        last = String(last.dropFirst().dropLast(".icloud".count))
        parts.append(last)
        return parts.joined(separator: "/")
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func mapped(_ error: Error) -> BackupProviderError {
        let error = error as NSError
        return ICloudDrive.error(
            domain: error.domain, code: error.code, description: error.localizedDescription)
    }
}
