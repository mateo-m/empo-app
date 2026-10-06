import Foundation

/// One namespace on one target, as section 10 reads it.
public struct SyncNamespace: Sendable {
    public let id: String
    public let record: DeviceRecord?
    /// The copy of the sync document, where the namespace holds one.
    public let document: RemoteObject?

    public init(id: String, record: DeviceRecord?, document: RemoteObject?) {
        self.id = id
        self.record = record
        self.document = document
    }
}

/// Why one pass runs, per SPEC 10.11.
public enum SyncTrigger: Sendable {
    /// Empo opened, or a join or a restore asked for a pass. It
    /// always reads every target.
    case now
    /// The user changed a setting, a binding, or a layout.
    case afterALocalChange
}

/// This device's copy of the sync document of SPEC 10.3.
///
/// Automerge is Apple-only, so the app holds the one implementation
/// and the engine holds the order of the steps.
@MainActor
public protocol SyncDocumentStore: AnyObject {

    /// Reads this device's copy again. A join deletes the file, per
    /// 10.4, so every pass starts from the file and not from the
    /// copy in memory.
    func load()

    func model() throws -> SyncDocumentModel
    func write(_ model: SyncDocumentModel) throws

    /// Merges one copy of another device in, per 10.5 step 2, or
    /// answers why it changed nothing.
    func merge(_ bytes: Data) -> Result<Void, SyncCopyRejection>

    /// The heads of 10.5 step 6, as text a state file can hold.
    func heads() -> [String]

    /// The control leaves the merge left with more than one value,
    /// per 10.6, mapped to the value the merge did not pick.
    func losingControls(profileId: String) -> [String: JSONValue]

    /// Writes the winner of each leaf back, which is how the merge
    /// resolves a conflict.
    func resolveControls(profileId: String, keys: [String])

    /// Saves the document to this device.
    func save() throws
}

/// What one pass reads from a target and writes back to it.
@MainActor
public protocol SyncTargets: AnyObject {

    /// The targets a pass reads, which is every one that is not
    /// paused.
    func enabled() -> [TargetDescriptor]

    func namespaces(of target: TargetDescriptor) async -> [SyncNamespace]
    func read(_ path: String, from target: TargetDescriptor) async -> Data?
    func write(_ data: Data, to path: String, on target: TargetDescriptor) async -> Bool

    /// Puts this device's document file and confirms it, per 10.5
    /// step 5. It answers the reason the target took no copy, or
    /// `nil` where the target took it.
    func putTheDocument(to path: String, on target: TargetDescriptor) async -> String?
}

/// The two sync files of SPEC 10.3 on this device.
///
/// Every change reads the file again first. A pass runs for seconds,
/// and a join or a profile rename lands in the middle of one.
@MainActor
public protocol SyncStateStore: AnyObject {
    func state() -> SyncState
    func update(_ change: (inout SyncState) -> Void) throws
    func updateIdentities(_ change: (inout SyncProfileIdentities) -> Void) throws
}

/// The values of this device that ride the document, per SPEC 10.1.
@MainActor
public protocol SyncLocalValuesStore: AnyObject {

    /// The document leaves this device would publish now.
    func read(identities: inout SyncProfileIdentities) -> SyncDocumentModel

    /// Applies the merged values to this device, per 10.5 step 4.
    func apply(_ model: SyncDocumentModel, identities: inout SyncProfileIdentities)
}
