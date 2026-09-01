import Automerge
import Foundation
import GameProbe

/// This device's copy of the sync document of SPEC 10.3.
///
/// The file sits beside the backup root, so a deleted root keeps the
/// causal history. Every read, write, and delete of
/// `preferences.automerge` goes through here.
@MainActor
enum SyncDocumentFile {

    /// Where the pass uploads the copy from. A put reads the file
    /// and not the document in memory, per 10.5 step 5.
    static var url: URL {
        BackupRoot.layout.syncDocumentFile
    }

    /// The document on this device, or a new one where the file is
    /// missing or unreadable.
    static func read(actorId: String) -> Document {
        guard let bytes = try? Data(contentsOf: url),
            let document = try? SyncDocument.open(bytes, actorId: actorId)
        else { return SyncDocument.make(actorId: actorId) }
        return document
    }

    static func write(_ document: Document) throws {
        try document.save().write(to: url, options: .atomic)
    }

    /// A join drops the local document, per 10.4. Two documents that
    /// never shared a history give the root a second `preferences`
    /// map, and Automerge answers one of the two.
    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
