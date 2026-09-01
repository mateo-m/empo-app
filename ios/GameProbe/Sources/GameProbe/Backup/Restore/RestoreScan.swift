import Foundation

/// One device namespace as the scan read it.
public struct ScannedNamespace: Sendable {

    public var id: String
    public var deviceId: String?
    /// The name `device.json` carries, or the namespace id where the
    /// namespace holds no record yet.
    public var deviceName: String
    public var gameRows: [SnapshotRow]
    public var preferencesRows: [SnapshotRow]
    /// The Rescued Saves buckets the newest preferences snapshot
    /// carries, per 5.3.
    public var rescuedSavesBuckets: [String]
}

/// What one target holds, for the two manual doors of SPEC 11.3 and
/// for the fresh-install scan.
///
/// The scan is read-only. It lists and reads, it writes nothing, and
/// it claims no namespace, so it never touches a namespace another
/// device owns.
public struct RestoreScan: Sendable {

    public let provider: any BackupProvider
    public let descriptor: TargetDescriptor

    public init(provider: any BackupProvider, descriptor: TargetDescriptor) {
        self.provider = provider
        self.descriptor = descriptor
    }

    /// Every namespace of the target, newest device first.
    ///
    /// `localMarkers` maps a game key to the marker of the local
    /// tree, so a row can carry the version-marker flag of 11.10. A
    /// fresh install passes none.
    public func namespaces(
        localMarkers: [String: SnapshotManifest.VersionMarker] = [:]
    ) async throws -> [ScannedNamespace] {
        let empo = BackupNamespacePaths(root: descriptor.root, namespaceId: "")
        let prefix = empo.devicesPrefix + "/"
        let listed = try await provider.list(prefix: prefix)

        var ids: Set<String> = []
        for object in listed {
            guard object.path.hasPrefix(prefix) else { continue }
            let rest = object.path.dropFirst(prefix.count)
            guard let id = rest.split(separator: "/").first else { continue }
            ids.insert(String(id))
        }

        var scanned: [ScannedNamespace] = []
        for id in ids.sorted() {
            scanned.append(try await namespace(id, localMarkers: localMarkers))
        }
        return scanned
    }

    private func namespace(
        _ id: String, localMarkers: [String: SnapshotManifest.VersionMarker]
    ) async throws -> ScannedNamespace {
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: id)
        let record = try await read(paths.deviceFile).flatMap {
            try? DeviceRecord.decode(json: $0)
        }

        var namespace = ScannedNamespace(
            id: id,
            deviceId: record?.deviceId,
            deviceName: record?.name ?? id,
            gameRows: [],
            preferencesRows: [],
            rescuedSavesBuckets: [])

        namespace.gameRows = try await rows(
            under: paths.gamesPrefix + "/", paths: paths, deviceName: namespace.deviceName,
            localMarkers: localMarkers)
        namespace.preferencesRows = try await rows(
            under: paths.preferencesPrefix + "/", paths: paths,
            deviceName: namespace.deviceName, localMarkers: [:])

        if let newest = RestorePicker.newestFirst(namespace.preferencesRows).first,
            let manifest = try await manifest(
                at: paths.manifestPath(stream: .preferences, snapshotId: newest.snapshotId))
        {
            namespace.rescuedSavesBuckets = Self.rescuedSavesBuckets(in: manifest)
        }
        return namespace
    }

    private func rows(
        under prefix: String,
        paths: BackupNamespacePaths,
        deviceName: String,
        localMarkers: [String: SnapshotManifest.VersionMarker]
    ) async throws -> [SnapshotRow] {
        var rows: [SnapshotRow] = []
        for object in try await provider.list(prefix: prefix) {
            guard let snapshotId = BackupNamespacePaths.snapshotId(ofManifestPath: object.path),
                let manifest = try await manifest(at: object.path)
            else { continue }
            rows.append(
                SnapshotRow(
                    manifest: manifest,
                    targetId: descriptor.id,
                    targetLabel: descriptor.label,
                    namespaceId: paths.namespaceId,
                    deviceName: deviceName,
                    snapshotId: snapshotId,
                    localVersionMarker: localMarkers[manifest.gameKey]))
        }
        return RestorePicker.newestFirst(rows)
    }

    /// The Rescued Saves buckets a preferences snapshot carries.
    ///
    /// On a fresh install nothing is installed, so every bucket the
    /// stream holds is orphaned, per 11.4.
    public static func rescuedSavesBuckets(in manifest: SnapshotManifest) -> [String] {
        let prefix = BackupSetResolver.rescuedSavesPathPrefix + "/"
        var names: Set<String> = []
        for entry in manifest.entries where entry.root == .preferences {
            guard entry.path.hasPrefix(prefix) else { continue }
            let rest = entry.path.dropFirst(prefix.count)
            guard let name = rest.split(separator: "/").first else { continue }
            names.insert(String(name))
        }
        return names.sorted()
    }

    // MARK: - Reading

    public func manifest(at path: String) async throws -> SnapshotManifest? {
        guard let data = try await read(path) else { return nil }
        return try? SnapshotManifest.decode(compressed: data)
    }

    private func read(_ path: String) async throws -> Data? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-restore-scan-\(UUID().uuidString)")
        do {
            try await provider.get(path: path, localFile: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            if error == .notFound { return nil }
            throw error
        }
        let data = try? Data(contentsOf: scratch)
        try? FileManager.default.removeItem(at: scratch)
        return data
    }
}
