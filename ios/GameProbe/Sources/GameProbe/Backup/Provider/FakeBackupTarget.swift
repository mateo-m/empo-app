import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A failure `FakeBackupTarget` produces on purpose.
///
/// Every error path of the snapshot engine is proved through these,
/// so each of the seven kinds of SPEC 8.4 can fire on a chosen
/// operation and a chosen path.
public struct FakeTargetFault: Equatable, Sendable {

    public enum Operation: String, CaseIterable, Equatable, Sendable {
        case list
        case put
        case confirm
        case get
        case delete
        case quota
    }

    /// Which phase of `put` the fault fires in. `put` is two
    /// phases, per 8.1, and the two behave differently: a failed
    /// upload moves no byte to the path, and a failed commit leaves
    /// the old content in place, per 8.2.
    public enum PutPhase: String, Equatable, Sendable {
        case upload
        case commit
    }

    public var operation: Operation
    /// Fires only on a path that holds this text. `nil` fires on
    /// every path.
    public var pathContains: String?
    public var error: BackupProviderError
    public var phase: PutPhase
    /// How many times it fires, or `nil` for every call.
    public var times: Int?

    public init(
        operation: Operation,
        error: BackupProviderError,
        pathContains: String? = nil,
        phase: PutPhase = .upload,
        times: Int? = nil
    ) {
        self.operation = operation
        self.pathContains = pathContains
        self.error = error
        self.phase = phase
        self.times = times
    }

    /// The case invariant 7 protects: every blob lands and the
    /// manifest never does, per 5.8.
    public static func crashBeforeTheManifest(
        error: BackupProviderError = .offline
    ) -> FakeTargetFault {
        FakeTargetFault(operation: .put, error: error, pathContains: "/games/")
    }
}

/// A provider that keeps its objects in a local directory.
///
/// It meets the whole protocol of SPEC section 8, so the snapshot
/// engine, the restore engine, preference sync, and the package
/// writer are all provable by `swift test`, with no account and no
/// network.
///
/// The on-disk shape is `<directory>/objects/<provider path>` for
/// the objects and `<directory>/staging/` for the two-phase put.
/// Staging sits outside the object tree, so a staged file that never
/// commits never shows up in `list`.
public actor FakeBackupTarget: BackupProvider {

    public nonisolated let capabilities: TargetCapabilities

    private let directory: URL
    private let gate: TransferGate
    private let confirmsLater: Bool

    private var faults: [FakeTargetFault] = []
    private var pendingConfirmations: Set<String> = []
    private var quotaLimitBytes: Int64?
    private var latch: TransferLatch?

    /// - `quotaLimitBytes`: the limit this target reports. `nil`
    ///   makes `quota` answer nothing, the way iCloud Drive and S3
    ///   do, per 9.7.
    /// - `confirmsLater`: makes a put commit and hold its
    ///   confirmation back, the way iCloud Drive does, per 8.5.
    ///   `finishPendingUploads` then confirms them.
    public init(
        directory: URL,
        capabilities: TargetCapabilities = TargetCapabilities(),
        quotaLimitBytes: Int64? = nil,
        confirmsLater: Bool = false,
        clock: BackupClock = SystemBackupClock(),
        attempts: Int = 3
    ) {
        self.directory = directory
        self.capabilities = capabilities
        self.quotaLimitBytes = quotaLimitBytes
        self.confirmsLater = confirmsLater
        self.gate = TransferGate(attempts: attempts, clock: clock)
    }

    // MARK: - The six operations

    public func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        let reportsAge = capabilities.reportsObjectAge
        let root = objectsDirectory
        return try await gate.request {
            [self] () async throws(BackupProviderError) -> [RemoteObject] in
            if let error = await fault(.list, path: prefix, phase: nil) { throw error }
            return FakeBackupTarget.walk(root)
                .filter { $0.path.hasPrefix(prefix) }
                .map { found in
                    RemoteObject(
                        path: found.path,
                        sizeBytes: FakeBackupTarget.fileSize(at: found.url),
                        modifiedAt: reportsAge
                            ? FakeBackupTarget.modifiedDate(at: found.url) : nil)
                }
                .sorted { $0.path < $1.path }
        }
    }

    public func put(localFile: URL, path: String) async throws(BackupProviderError) {
        // Before any byte moves, per 8.3.
        let size = FakeBackupTarget.fileSize(at: localFile)
        if let rejection = capabilities.rejection(forFileOfSize: size) { throw rejection }

        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        let latch = self.latch
        // Both phases run inside one slot. A real provider commits
        // with a request of its own, and that request answers 429
        // like any other, so the gate must cover it.
        try await gate.transfer { [self] () async throws(BackupProviderError) in
            if let error = await fault(.put, path: path, phase: .upload) { throw error }
            await latch?.wait()
            try FakeBackupTarget.copyFile(from: localFile, to: staged)
            if let error = await fault(.put, path: path, phase: .commit) {
                // The staged copy never becomes the object, so the
                // path still holds the old content, per 8.2.
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            try commit(staged: staged, to: path)
        }
        if confirmsLater { pendingConfirmations.insert(path) }
    }

    /// It takes no slot and no throttle wait. Five of the six v1
    /// providers confirm at their commit and make no call here, and
    /// the sixth reads a local metadata query, per 8.5 and 9.1.
    public func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        if let error = fault(.confirm, path: path, phase: nil) { throw error }
        guard FileManager.default.fileExists(atPath: fileURL(forPath: path).path) else {
            throw BackupProviderError.notFound
        }
        return pendingConfirmations.contains(path) ? .pending : .confirmed
    }

    public func get(path: String, localFile: URL) async throws(BackupProviderError) {
        let source = fileURL(forPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BackupProviderError.notFound
        }
        let latch = self.latch
        try await gate.transfer { [self] () async throws(BackupProviderError) in
            if let error = await fault(.get, path: path, phase: nil) { throw error }
            await latch?.wait()
            try FakeBackupTarget.copyFile(from: source, to: localFile)
        }
    }

    public func delete(paths: [String]) async throws(BackupProviderError) {
        try await gate.request { [self] () async throws(BackupProviderError) in
            for path in paths {
                if let error = await fault(.delete, path: path, phase: nil) { throw error }
            }
            await removeObjects(paths)
        }
    }

    public func quota() async throws(BackupProviderError) -> QuotaReading? {
        try await gate.request { [self] () async throws(BackupProviderError) -> QuotaReading? in
            if let error = await fault(.quota, path: nil, phase: nil) { throw error }
            return await currentQuota()
        }
    }

    private func currentQuota() -> QuotaReading? {
        guard let quotaLimitBytes else { return nil }
        return QuotaReading(usedBytes: usedBytes(), limitBytes: quotaLimitBytes)
    }

    private func removeObjects(_ paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(at: fileURL(forPath: path))
            pendingConfirmations.remove(path)
        }
    }

    // MARK: - What a test drives

    public func addFault(_ fault: FakeTargetFault) {
        faults.append(fault)
    }

    public func removeFaults() {
        faults = []
    }

    /// Holds every transfer at the latch until the test opens it.
    public func setLatch(_ latch: TransferLatch?) {
        self.latch = latch
    }

    /// Confirms every put that was waiting, the way the iCloud
    /// daemon reports an item uploaded.
    public func finishPendingUploads() {
        pendingConfirmations = []
    }

    public func setQuotaLimit(_ bytes: Int64?) {
        quotaLimitBytes = bytes
    }

    /// Puts an object on the target without going through `put`.
    ///
    /// A second device's `writer.json` is what this is for: the
    /// claim of 5.12 names another device, and this device must find
    /// it there before its first write.
    public func seed(path: String, contents: Data) throws {
        let url = fileURL(forPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, options: .atomic)
    }

    /// The bytes at `path`, or `nil` where the target holds no
    /// object there.
    public func contents(atPath path: String) -> Data? {
        try? Data(contentsOf: fileURL(forPath: path))
    }

    public var peakInFlight: Int {
        get async { await gate.peakInFlight }
    }

    public var waitedSeconds: [TimeInterval] {
        get async { await gate.waitedSeconds }
    }

    /// Every byte the target holds.
    public func usedBytes() -> Int64 {
        FakeBackupTarget.walk(objectsDirectory)
            .reduce(into: Int64(0)) { total, found in
                total += FakeBackupTarget.fileSize(at: found.url)
            }
    }

    // MARK: - Paths

    public nonisolated var objectsDirectory: URL {
        directory.appendingPathComponent("objects", isDirectory: true)
    }

    private nonisolated var stagingDirectory: URL {
        directory.appendingPathComponent("staging", isDirectory: true)
    }

    public nonisolated func fileURL(forPath path: String) -> URL {
        var url = objectsDirectory
        for part in path.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
        }
        return url
    }

    // MARK: - Inside

    /// The error this call must report, or `nil` where no fault
    /// matches it.
    ///
    /// It returns the error rather than throwing it, so a caller
    /// can clean up before the error leaves.
    private func fault(
        _ operation: FakeTargetFault.Operation,
        path: String?,
        phase: FakeTargetFault.PutPhase?
    ) -> BackupProviderError? {
        for index in faults.indices {
            let fault = faults[index]
            guard fault.operation == operation else { continue }
            if let phase, fault.phase != phase { continue }
            if let wanted = fault.pathContains {
                guard let path, path.contains(wanted) else { continue }
            }
            if let times = fault.times {
                guard times > 0 else { continue }
                faults[index].times = times - 1
            }
            return fault.error
        }
        return nil
    }

    private nonisolated func commit(staged: URL, to path: String) throws(BackupProviderError) {
        let destination = fileURL(forPath: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw .rejected(message: "the fake target could not open the path \(path)")
        }
        // POSIX rename replaces the destination in one step, so a
        // reader sees the old content or the new content and never a
        // partial one, per 8.2.
        guard rename(staged.path, destination.path) == 0 else {
            throw .rejected(message: "the fake target could not commit \(path)")
        }
    }

    private static func copyFile(from source: URL, to destination: URL) throws(BackupProviderError) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
        } catch {
            throw .rejected(
                message: "the fake target could not read \(source.lastPathComponent)")
        }
    }

    /// Every file under `base`, with the path each one holds on the
    /// target. `FileManager.enumerator` cannot run in an async
    /// context, so the walk lives in its own plain function.
    private static func walk(_ base: URL) -> [(path: String, url: URL)] {
        let manager = FileManager.default
        let root = base.standardizedFileURL.path
        guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [(path: String, url: URL)] = []
        for case let url as URL in walker {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            found.append((String(full.dropFirst(root.count + 1)), url))
        }
        return found
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func modifiedDate(at url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
