import Automerge
import Foundation
import GameProbe

/// This device's copy of the sync document of SPEC 10.3.
///
/// The file sits beside the backup root, so a deleted root keeps the
/// causal history. Every read, write, and delete of
/// `preferences.automerge` goes through here.
@MainActor
final class AutomergeDocumentStore: SyncDocumentStore {

    /// Where the pass uploads the copy from. A put reads the file
    /// and not the document in memory, per 10.5 step 5.
    static var url: URL {
        BackupRoot.layout.syncDocumentFile
    }

    static func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// The file, or `nil` where this device holds none. It throws
    /// for every other read error.
    static func bytes() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private var document = Document()
    /// The read error of the last `load`. `SyncDocumentStore.load`
    /// cannot throw, and `SyncEngine` reads an empty document as a new
    /// device. `SyncPass` reads the file before each pass, and `save`
    /// refuses to write while this is set, so that an empty document
    /// cannot replace a file that the pass could not read.
    private var unreadFile: Error?

    func load() {
        let bytes: Data
        do {
            unreadFile = nil
            guard let read = try Self.bytes() else {
                document = SyncDocument.make(actorId: SyncStore.newActorId())
                return
            }
            bytes = read
        } catch {
            unreadFile = error
            BackupLog.line("SyncDocument", "The local document was not read: \(error)")
            document = Document()
            return
        }
        do {
            document = try SyncDocument.open(bytes, actorId: SyncStore.state().actorId)
        } catch {
            BackupLog.line("SyncDocument", "The local document is damaged, so a new one starts: \(error)")
            document = SyncDocument.make(actorId: SyncStore.newActorId())
        }
    }

    func model() throws -> SyncDocumentModel {
        try SyncDocument.model(of: document)
    }

    func write(_ model: SyncDocumentModel) throws {
        try SyncDocument.write(model, to: document)
    }

    func merge(_ bytes: Data) -> Result<Void, SyncCopyRejection> {
        var copy: Document?
        let result = SyncCopyValidation.check(bytes) { data in
            let loaded = try Document(data)
            copy = loaded
            return try SyncDocument.model(of: loaded)
        }
        if case .failure(let rejection) = result { return .failure(rejection) }
        guard let copy, (try? document.merge(other: copy)) != nil else {
            return .failure(.unreadable("the copy did not merge"))
        }
        return .success(())
    }

    func heads() -> [String] {
        SyncDocument.heads(of: document)
    }

    func losingControls(profileId: String) -> [[String: JSONValue]] {
        do {
            return try SyncDocument.losingControls(of: document, profileId: profileId)
        } catch {
            BackupLog.line("SyncDocument", "The conflicts of \(profileId) were not read: \(error)")
            return []
        }
    }

    func resolveControls(profileId: String, keys: [String]) {
        do {
            try SyncDocument.resolveControls(of: document, profileId: profileId, keys: keys)
        } catch {
            BackupLog.line("SyncDocument", "The conflicts of \(profileId) were not resolved: \(error)")
        }
    }

    func save() throws {
        if let unreadFile { throw unreadFile }
        try document.save().write(to: Self.url, options: .atomic)
    }
}
