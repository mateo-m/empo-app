import Foundation
import GameProbe

/// The two sync files beside the backup root, per SPEC 10.3.
///
/// `sync.json` holds the actor identity and the group. The actor id
/// changes only with a new document, because a second id would
/// split this device's own history in the document. The Keychain
/// holds a second copy that does not move to a new phone, so a file
/// that a backup restored there gets a fresh id.
@MainActor
enum SyncStore {

    /// For the changes to `sync.json` alone. A Keychain error is not
    /// "this device holds no id", so the id in the file stays. A fresh
    /// id here would split this device's history.
    static func state() throws -> SyncState {
        let deviceActorId: String?
        do {
            deviceActorId = try BackupKeychain.syncActorId()
        } catch {
            BackupLog.line("SyncStore", "The actor id was not read: \(error)")
            return try SyncState.read(
                applicationSupport: BackupRoot.layout.applicationSupport, actorId: UUID().uuidString)
        }
        return try state(deviceActorId: deviceActorId)
    }

    /// The pass writes the document as this actor, so it reads the state
    /// only after the Keychain answers.
    static func state(deviceActorId: String?) throws -> SyncState {
        let url = BackupRoot.layout.applicationSupport.appendingPathComponent(SyncState.fileName)
        var state = try SyncState.read(
            applicationSupport: BackupRoot.layout.applicationSupport, actorId: UUID().uuidString)
        let replaced = state.replaceActor(
            unlessTheDeviceHolds: deviceActorId, fresh: { UUID().uuidString })
        if replaced {
            logFailure("The actor id was not saved") {
                try BackupKeychain.setSyncActorId(state.actorId)
            }
        }
        if replaced || !FileManager.default.fileExists(atPath: url.path) {
            logFailure("sync.json was not saved") {
                try state.write(applicationSupport: BackupRoot.layout.applicationSupport)
            }
        }
        return state
    }

    /// Nothing repairs a damaged file, so sync stays off until the user sets it up again.
    static func settingsAreDamaged() -> Bool {
        do {
            _ = try SyncState.read(applicationSupport: BackupRoot.layout.applicationSupport, actorId: "")
            return false
        } catch is DecodingError {
            return true
        } catch {
            return false
        }
    }

    static func setAsideTheDamagedFile() throws {
        guard settingsAreDamaged() else { return }
        try BackupRoot.setAside(
            BackupRoot.layout.applicationSupport.appendingPathComponent(SyncState.fileName))
    }

    /// Other devices hold the changes of the old id, numbered from 1.
    /// A new document that writes as that id numbers from 1 again,
    /// and Automerge refuses every copy that holds both.
    static func newActorId() -> String {
        let actorId = UUID().uuidString
        logFailure("The actor id was not saved") { try BackupKeychain.setSyncActorId(actorId) }
        logFailure("sync.json was not saved") { try update { $0.actorId = actorId } }
        return actorId
    }

    private static func logFailure(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            BackupLog.line("SyncStore", "\(what): \(error)")
        }
    }

    /// Changes the state on the file and not on a copy.
    ///
    /// A pass runs for seconds and a join lands in the middle of one.
    /// A caller that read the state before the join and wrote it back
    /// after would put the old group back, so every change reads the
    /// file again first.
    static func update(_ change: (inout SyncState) -> Void) throws {
        var state = try state()
        change(&state)
        try state.write(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    static func identities() throws -> SyncProfileIdentities {
        try SyncProfileIdentities.read(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    /// Changes the profile identities on the file and not on a copy,
    /// for the same reason `update` does.
    static func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
        var identities = try identities()
        change(&identities)
        try identities.write(applicationSupport: BackupRoot.layout.applicationSupport)
    }

    // MARK: - What the profile store reports

    /// A delete travels as its own record, per 10.6, so the identity
    /// has to outlive the folder until the next pass publishes it.
    static func profileWasDeleted(_ name: String) {
        logFailure("The delete of \(name) was not saved") {
            try updateIdentities { $0.markDeleted(profile: name, at: Date()) }
        }
    }

    static func profileWasRenamed(from oldName: String, to newName: String) {
        logFailure("The rename of \(oldName) was not saved") {
            try updateIdentities { identities in
                guard identities.knownId(ofProfile: oldName) != nil else { return }
                identities.rename(from: oldName, to: newName)
            }
        }
    }
}

/// The two sync files as the pass reads and changes them.
@MainActor
final class SyncFileStore: SyncStateStore {

    private let readTheDeviceActorId: @MainActor () throws -> String?

    init(deviceActorId: @escaping @MainActor () throws -> String? = BackupKeychain.syncActorId) {
        readTheDeviceActorId = deviceActorId
    }

    func state() throws -> SyncState {
        try SyncStore.state(deviceActorId: try readTheDeviceActorId())
    }

    func update(_ change: (inout SyncState) -> Void) throws {
        try SyncStore.update(change)
    }

    func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws {
        try SyncStore.updateIdentities(change)
    }
}
