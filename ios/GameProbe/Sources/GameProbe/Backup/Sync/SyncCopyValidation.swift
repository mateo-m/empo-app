import Foundation

/// Why a copy of the sync document changed nothing, per SPEC 10.5.
public enum SyncCopyRejection: Error, Equatable, Sendable {
    /// The object holds no bytes.
    case empty
    /// Automerge could not read the bytes. A truncated copy and a
    /// corrupt copy both land here.
    case unreadable(String)
    /// The document needs a writer this build does not have, per
    /// 10.10.
    case unsupported(minimumWriterVersion: Int)
}

/// Step 2 of the replication pass of 10.5.
///
/// A rejected copy changes nothing. The caller merges what this
/// returns, so a copy that fails any check never reaches the local
/// document.
public enum SyncCopyValidation {

    /// The checks in order, over one copy.
    ///
    /// `read` is the Automerge load, which lives in the app. It
    /// throws on a truncated or corrupt copy.
    public static func check(
        _ bytes: Data, read: (Data) throws -> SyncDocumentModel
    ) -> Result<SyncDocumentModel, SyncCopyRejection> {
        guard !bytes.isEmpty else { return .failure(.empty) }
        let model: SyncDocumentModel
        do {
            model = try read(bytes)
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
        guard SyncSchema.canPublish(toDocumentRequiring: model.minimumWriterVersion) else {
            return .failure(.unsupported(minimumWriterVersion: model.minimumWriterVersion))
        }
        return .success(model)
    }

    /// Whether this build still reads a document it may not write,
    /// per 10.10. It keeps the fields it knows.
    public static func readsButDoesNotPublish(_ model: SyncDocumentModel) -> Bool {
        !SyncSchema.canPublish(toDocumentRequiring: model.minimumWriterVersion)
    }
}
