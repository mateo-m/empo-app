import Foundation

/// A staged package as a restore source, per SPEC 12.6.
///
/// The package answers the same six operations a target answers, so
/// the restore engine of section 11 reads it with no change. It is
/// still not a target, per 12.7: it never becomes a device
/// namespace, it never offers adopt, and it never joins the
/// namespace list.
///
/// Only `get` does work. A restore reads three kinds of path, and
/// this source answers two of them from the ZIP:
///
/// - `format.json`, which a package does not carry, so the engine
///   falls back to the version 1 fan-out width.
/// - one manifest per stream, built from `manifest.json`.
/// - one blob per hash, which is the file itself at its own path.
public actor PackageSource: BackupProvider {

    /// What a package id looks like where a target id goes. The
    /// prefix is what tells a restore record that the source was a
    /// package and not a configured target.
    public static let targetIdPrefix = "package:"

    public static func targetId(packageId: String) -> String {
        targetIdPrefix + packageId
    }

    /// The package a target id names, or `nil` for a real target.
    public static func packageId(ofTargetId targetId: String) -> String? {
        guard targetId.hasPrefix(targetIdPrefix) else { return nil }
        return String(targetId.dropFirst(targetIdPrefix.count))
    }

    public nonisolated let packageId: String
    public nonisolated let manifest: PackageManifest
    /// A package has no target root, so the paths sit at the top.
    public nonisolated let paths: BackupNamespacePaths

    private let reader: ZipReader
    /// The compressed manifest of each stream, by the path the
    /// engine asks for.
    private let manifests: [String: Data]
    /// The file each blob path stands for.
    private let blobs: [String: PackageFile]
    private let fm = FileManager.default

    /// Opens a staged package and checks it, before any restore
    /// reads a byte of it.
    public init(zip url: URL, packageId: String) throws {
        guard let reader = try? ZipReader(reading: url) else {
            throw PackageRejection.noManifest
        }
        let entries = reader.entries
        let data = reader.entry(at: PackageLayout.manifestPath).flatMap { try? reader.data(of: $0) }
        let manifest = try PackageValidation.manifest(ofZip: entries, data: data)
        do {
            try PackageValidation.check(manifest, against: entries)
        } catch {
            reader.close()
            throw error
        }

        let paths = BackupNamespacePaths(root: "", namespaceId: packageId)
        var manifests: [String: Data] = [:]
        for stream in manifest.streams {
            let path = paths.manifestPath(
                stream: BackupStream(key: stream.key),
                snapshotId: Self.snapshotId(streamKey: stream.key, exportedAt: manifest.exportedAt))
            manifests[path] = try stream.manifest.compressedData()
        }
        var blobs: [String: PackageFile] = [:]
        for file in manifest.files {
            let path = paths.blobPath(
                hash: file.entry.hash, fanOutWidth: FormatDescriptor.version1FanOutWidth)
            blobs[path] = file
        }

        self.packageId = packageId
        self.manifest = manifest
        self.paths = paths
        self.reader = reader
        self.manifests = manifests
        self.blobs = blobs
    }

    public func close() {
        reader.close()
    }

    // MARK: - The rows, per 12.6

    /// The snapshot id one stream takes.
    ///
    /// It carries the export date, so the picker shows the package
    /// date, and it stays the same on a second open, so a deferred
    /// import finds the same row.
    public static func snapshotId(streamKey: String, exportedAt: Date) -> String {
        var suffix = String(streamKey.filter { $0.isNumber || ($0 >= "a" && $0 <= "f") }.prefix(6))
        suffix += String(repeating: "0", count: max(0, 6 - suffix.count))
        return BackupKeys.snapshotId(date: exportedAt, suffix: suffix)
    }

    /// One row per included stream, per 12.6. The package date and
    /// the source device take the places a target restore gives to
    /// a namespace and a device.
    public static func rows(
        of manifest: PackageManifest,
        packageId: String,
        localVersionMarkers: [String: SnapshotManifest.VersionMarker] = [:]
    ) -> [SnapshotRow] {
        manifest.streams.map { stream in
            SnapshotRow(
                manifest: stream.manifest,
                targetId: targetId(packageId: packageId),
                targetLabel: manifest.sourceDevice,
                namespaceId: packageId,
                deviceName: manifest.sourceDevice,
                snapshotId: snapshotId(streamKey: stream.key, exportedAt: manifest.exportedAt),
                localVersionMarker: localVersionMarkers[stream.key])
        }
    }

    // MARK: - The six operations of 8.1

    public nonisolated var capabilities: TargetCapabilities {
        TargetCapabilities(canQueryQuota: false, reportsObjectAge: false)
    }

    public func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
        []
    }

    public func put(localFile: URL, path: String) async throws(BackupProviderError) {
        throw .rejected(message: "a backup package takes no writes")
    }

    public func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation {
        throw .notFound
    }

    public func delete(paths: [String]) async throws(BackupProviderError) {}

    public func quota() async throws(BackupProviderError) -> QuotaReading? {
        nil
    }

    /// Answers one read out of the ZIP.
    ///
    /// A blob check happens here and not in the engine, because this
    /// is where the package's own numbers are. The size and the hash
    /// both have to match before the file reaches the restore
    /// staging area, per 12.6.
    public func get(path: String, localFile: URL) async throws(BackupProviderError) {
        if let data = manifests[path] {
            guard (try? data.write(to: localFile, options: .atomic)) != nil else {
                throw .rejected(message: "this device could not stage the package list of files")
            }
            return
        }
        guard let file = blobs[path], let entry = reader.entry(at: file.zipPath) else {
            throw .notFound
        }
        do {
            try reader.extract(entry, to: localFile)
            let size = Int64(
                (try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try PackageValidation.checkTheContent(
                of: file,
                stagedSize: size,
                stagedHash: (try? ContentHash.hexOfFile(at: localFile)) ?? "")
        } catch {
            try? fm.removeItem(at: localFile)
            throw .rejected(message: Self.line(of: error, path: file.zipPath))
        }
    }

    private static func line(of error: Error, path: String) -> String {
        guard let rejection = error as? PackageRejection else {
            return PackageRejection.missingFile(path).line
        }
        return rejection.line
    }
}
