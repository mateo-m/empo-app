import Foundation
import GameProbe

/// The reads and writes section 10 makes on a target.
///
/// The provider takes a file and not bytes, per 8.1, so every call
/// here goes through a temporary file.
enum SyncRemote {

    static func read(_ path: String, from provider: some BackupProvider) async -> Data? {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await provider.get(path: path, localFile: file)
        } catch {
            return nil
        }
        return try? Data(contentsOf: file)
    }

    static func write(
        _ data: Data, to path: String, with provider: some BackupProvider
    ) async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .atomic)
        try await provider.put(localFile: file, path: path)
    }

    /// What one target holds for every namespace, per 5.1.
    ///
    /// One listing answers both readers: the join step of 10.4 reads
    /// the group of each record, and the pass of 10.5 reads the copy
    /// of each namespace that shares its group.
    static func namespaces(
        root: String, provider: some BackupProvider
    ) async -> [SyncNamespace] {
        let empo = BackupNamespacePaths(root: root, namespaceId: "")
        let prefix = empo.devicesPrefix + "/"
        guard let objects = try? await provider.list(prefix: prefix) else { return [] }

        var documents: [String: RemoteObject] = [:]
        var ids: Set<String> = []
        for object in objects {
            let rest = object.path.dropFirst(prefix.count)
            guard let id = rest.split(separator: "/").first.map(String.init) else { continue }
            ids.insert(id)
            if object.path.hasSuffix("/" + BackupNamespacePaths.syncDocumentFileName) {
                documents[id] = object
            }
        }

        var out: [SyncNamespace] = []
        for id in ids.sorted() {
            let paths = BackupNamespacePaths(root: root, namespaceId: id)
            let record = await read(paths.deviceFile, from: provider)
                .flatMap { try? DeviceRecord.decode(json: $0) }
            out.append(SyncNamespace(id: id, record: record, document: documents[id]))
        }
        return out
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

/// One namespace on one target, as section 10 reads it.
struct SyncNamespace {
    let id: String
    let record: DeviceRecord?
    /// The copy of the sync document, where the namespace holds one.
    let document: RemoteObject?
}
