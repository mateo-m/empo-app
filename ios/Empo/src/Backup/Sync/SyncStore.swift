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
        let url = BackupRoot.layout.applicationSupport.appendingPathComponent(SyncState.fileName)
        let state = SyncState.read(
            applicationSupport: BackupRoot.layout.applicationSupport, actorId: UUID().uuidString)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? state.write(applicationSupport: BackupRoot.layout.applicationSupport)
        }
        return state
    }

    /// Changes the state on the file and not on a copy.
    ///
    /// A pass runs for seconds and a join lands in the middle of one.
    /// A caller that read the state before the join and wrote it back
    /// after would put the old group back, so every change reads the
    /// file again first.
    static func update(_ change: (inout SyncState) -> Void) throws {
        var state = state()
        change(&state)
        try state.write(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    static func identities() -> SyncProfileIdentities {
        SyncProfileIdentities.read(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    /// Changes the profile identities on the file and not on a copy,
    /// for the same reason `update` does.
    static func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
        var identities = identities()
        change(&identities)
        try identities.write(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    // MARK: - What the profile store reports

    /// A delete travels as its own record, per 10.6, so the identity
    /// has to outlive the folder until the next pass publishes it.
    static func profileWasDeleted(_ name: String) {
        try? updateIdentities { $0.markDeleted(profile: name, at: Date()) }
    }

    static func profileWasRenamed(from oldName: String, to newName: String) {
        try? updateIdentities { identities in
            guard identities.knownId(ofProfile: oldName) != nil else { return }
            identities.rename(from: oldName, to: newName)
        }
    }
}

/// The two sync files as the pass reads and changes them.
@MainActor
final class SyncFileStore: SyncStateStore {

    func state() -> SyncState {
        SyncStore.state()
    }

    func update(_ change: (inout SyncState) -> Void) throws {
        try SyncStore.update(change)
    }

    func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
        try SyncStore.updateIdentities(change)
    }
}
