import Foundation
import GameProbe

/// The two sync files beside the backup root, per SPEC 10.3.
///
/// `sync.json` holds the actor identity and the group. The actor id
/// is minted once and written at once, because a second mint would
/// split this device's own history in the document.
@MainActor
enum SyncStore {

    static func state() -> SyncState {
        let url = BackupRoot.applicationSupport.appendingPathComponent(SyncState.fileName)
        let state = SyncState.read(
            applicationSupport: BackupRoot.applicationSupport, actorId: UUID().uuidString)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? state.write(applicationSupport: BackupRoot.applicationSupport)
        }
        return state
    }

    static func save(_ state: SyncState) {
        try? state.write(applicationSupport: BackupRoot.applicationSupport)
    }

    static func identities() -> SyncProfileIdentities {
        SyncProfileIdentities.read(applicationSupport: BackupRoot.applicationSupport)
    }

    static func save(_ identities: SyncProfileIdentities) {
        try? identities.write(applicationSupport: BackupRoot.applicationSupport)
    }

    // MARK: - What the profile store reports

    /// A delete travels as its own record, per 10.6, so the identity
    /// has to outlive the folder until the next pass publishes it.
    static func profileWasDeleted(_ name: String) {
        var identities = identities()
        identities.markDeleted(profile: name, at: Date())
        save(identities)
    }

    static func profileWasRenamed(from oldName: String, to newName: String) {
        var identities = identities()
        guard identities.knownId(ofProfile: oldName) != nil else { return }
        identities.rename(from: oldName, to: newName)
        save(identities)
    }
}
