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

    /// A join drops the local document, per 10.4. Two documents that
    /// never shared a history give the root a second `preferences`
    /// map, and Automerge answers one of the two.
    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    private let readTheActorId: @MainActor () -> String
    private var document = Document()

    init(actorId: @escaping @MainActor () -> String = { SyncStore.state().actorId }) {
        readTheActorId = actorId
    }

    func load() {
        let actorId = readTheActorId()
        guard let bytes = try? Data(contentsOf: Self.url),
            let opened = try? SyncDocument.open(bytes, actorId: actorId)
        else {
            document = SyncDocument.make(actorId: actorId)
            return
        }
        document = opened
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

    func losingControls(profileId: String) -> [String: JSONValue] {
        (try? SyncDocument.losingControls(of: document, profileId: profileId)) ?? [:]
    }

    func resolveControls(profileId: String, keys: [String]) {
        try? SyncDocument.resolveControls(of: document, profileId: profileId, keys: keys)
    }

    func save() throws {
        try document.save().write(to: Self.url, options: .atomic)
    }
}
