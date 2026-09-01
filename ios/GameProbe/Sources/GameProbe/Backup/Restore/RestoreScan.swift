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

    /// The id of every namespace on the target, in order.
    public func namespaceIds() async throws -> [String] {
        let empo = BackupNamespacePaths(root: descriptor.root, namespaceId: "")
        let prefix = empo.devicesPrefix + "/"

        var ids: Set<String> = []
        for object in try await provider.list(prefix: prefix) {
            guard object.path.hasPrefix(prefix) else { continue }
            let rest = object.path.dropFirst(prefix.count)
            guard let id = rest.split(separator: "/").first else { continue }
            ids.insert(String(id))
        }
        return ids.sorted()
    }

    /// Every namespace of the target, newest device first.
    ///
    /// `localMarkers` maps a game key to the marker of the local
    /// tree, so a row can carry the version-marker flag of 11.10. A
    /// fresh install passes none.
    public func namespaces(
        localMarkers: [String: SnapshotManifest.VersionMarker] = [:]
    ) async throws -> [ScannedNamespace] {
        var scanned: [ScannedNamespace] = []
        for id in try await namespaceIds() {
            scanned.append(try await namespace(id, localMarkers: localMarkers))
        }
        return scanned
    }

    /// One game's rows in every namespace of the target, per 11.3.
    ///
    /// The door of one game lists one prefix for each namespace, so
    /// it reads no manifest of another game.
    public func rows(
        of stream: BackupStream,
        localMarker: SnapshotManifest.VersionMarker? = nil
    ) async throws -> [SnapshotRow] {
        let markers = localMarker.map { [stream.key: $0] } ?? [:]
        var found: [SnapshotRow] = []
        for id in try await namespaceIds() {
            let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: id)
            found += try await rows(
                under: paths.prefix(of: stream), paths: paths,
                deviceName: try await deviceRecord(paths)?.name ?? id,
                localMarkers: markers)
        }
        return RestorePicker.newestFirst(found)
    }

    /// One namespace, with every game it holds.
    public func namespace(
        _ id: String, localMarkers: [String: SnapshotManifest.VersionMarker] = [:]
    ) async throws -> ScannedNamespace {
        let paths = BackupNamespacePaths(root: descriptor.root, namespaceId: id)
        let record = try await deviceRecord(paths)

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

    private func deviceRecord(_ paths: BackupNamespacePaths) async throws -> DeviceRecord? {
        try await read(paths.deviceFile).flatMap { try? DeviceRecord.decode(json: $0) }
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
        var names: Set<String> = []
        for entry in manifest.entries where entry.root == .preferences {
            guard case .rescuedSavesBucket(let name, _) = PreferencesMemberPath(entry.path) else {
                continue
            }
            names.insert(name)
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
