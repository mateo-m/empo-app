import Foundation
import GameProbe

enum SyncRemote {

    /// `nil` only where the target holds no file at `path`. Every
    /// other failure throws, so that a caller cannot read it as
    /// "absent" and write a fresh file over one it could not read.
    static func read(_ path: String, from provider: some BackupProvider) async throws -> Data? {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        do throws(BackupProviderError) {
            try await provider.get(path: path, localFile: file)
        } catch .notFound {
            return nil
        }
        return try Data(contentsOf: file)
    }

    static func write(
        _ data: Data, to path: String, with provider: some BackupProvider
    ) async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .atomic)
        try await provider.put(localFile: file, path: path)
    }

    /// `nil` where the target did not answer the listing, or where a
    /// `device.json` that it holds could not be read.
    static func namespaces(
        root: String, provider: some BackupProvider
    ) async -> [SyncNamespace]? {
        let empo = BackupNamespacePaths(root: root, namespaceId: "")
        let prefix = empo.devicesPrefix + "/"
        let objects: [RemoteObject]
        do {
            objects = try await provider.list(prefix: prefix)
        } catch {
            BackupLog.line("SyncRemote", "\(prefix) was not listed: \(error)")
            return nil
        }

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
            let record: DeviceRecord?
            do {
                record = try await read(paths.deviceFile, from: provider)
                    .map { try DeviceRecord.decode(json: $0) }
            } catch {
                BackupLog.line("SyncRemote", "\(paths.deviceFile) was not read: \(error)")
                return nil
            }
            out.append(SyncNamespace(id: id, record: record, document: documents[id]))
        }
        return out
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

@MainActor
final class ProviderSyncTargets: SyncTargets {

    private struct FileOnTarget: Hashable {
        let targetId: String
        let path: String
    }

    /// The files whose last read failed for a reason other than "not
    /// found". `SyncTargets.read` answers `nil` for both, and
    /// `SyncEngine` writes a fresh `device.json` where it reads `nil`.
    /// `write` refuses these files, so that a fresh file cannot
    /// replace one that this device could not read.
    private var unreadFiles: Set<FileOnTarget> = []

    func enabled() -> [TargetDescriptor] {
        BackupTargets.writable()
    }

    func namespaces(of target: TargetDescriptor) async -> [SyncNamespace]? {
        guard let provider = await BackupTargets.provider(for: target) else { return nil }
        return await SyncRemote.namespaces(root: target.root, provider: provider)
    }

    func read(_ path: String, from target: TargetDescriptor) async -> Data? {
        let file = FileOnTarget(targetId: target.id, path: path)
        guard let provider = await BackupTargets.provider(for: target) else {
            unreadFiles.insert(file)
            return nil
        }
        do {
            let data = try await SyncRemote.read(path, from: provider)
            unreadFiles.remove(file)
            return data
        } catch {
            unreadFiles.insert(file)
            BackupLog.line("SyncRemote", "\(path) on \(target.label) was not read: \(error)")
            return nil
        }
    }

    func write(_ data: Data, to path: String, on target: TargetDescriptor) async -> Bool {
        guard !unreadFiles.contains(FileOnTarget(targetId: target.id, path: path)) else {
            BackupLog.line("SyncRemote", "\(path) on \(target.label) was not written: its read failed")
            return false
        }
        guard let provider = await BackupTargets.provider(for: target) else { return false }
        do {
            try await SyncRemote.write(data, to: path, with: provider)
            return true
        } catch {
            BackupLog.line("SyncRemote", "\(path) on \(target.label) was not written: \(error)")
            return false
        }
    }

    func putTheDocument(to path: String, on target: TargetDescriptor) async -> String? {
        guard let provider = await BackupTargets.provider(for: target) else {
            return "this device could not open the location"
        }
        do {
            try await provider.put(localFile: AutomergeDocumentStore.url, path: path)
            guard try await provider.confirm(path: path) == .confirmed else {
                return "the location did not confirm the copy"
            }
        } catch {
            return String(describing: error)
        }
        return nil
    }
}
