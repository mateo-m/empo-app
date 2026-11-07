import Foundation

/// What this install knows about its sync group, per SPEC 10.3 and
/// 10.5.
///
/// It sits beside the backup root, not inside it, because Empo may
/// delete the root whole. The actor identity has to outlive that:
/// a new actor id on every cache clear would split this device's own
/// history.
public struct SyncState: Codable, Equatable, Sendable {

    public static let currentVersion = 1
    public static let fileName = "sync.json"

    public var version: Int
    /// This install's Automerge actor identity. One per install, and
    /// it never travels.
    public var actorId: String
    /// The group this device joined, per 10.4, or `nil` before the
    /// join.
    public var groupId: String?
    /// What each target confirmed, per 10.5 step 6.
    public var targets: [SyncTargetProgress]
    /// The targets this device removed. The merged document still
    /// carries them, and a pass must not add them back here.
    public var removedTargetIds: [String]
    /// The preferences a rollback of 10.9 removed here. A missing
    /// local key is not a delete, so the next pass deletes these from
    /// the document by name.
    public var removedPreferenceKeys: [String]
    /// The global binding ids this device held after its last saved
    /// pass. One missing from the device now was removed here, and a
    /// missing local key is not a delete on its own.
    public var heldBindingIds: [String]

    public init(
        version: Int = SyncState.currentVersion,
        actorId: String,
        groupId: String? = nil,
        targets: [SyncTargetProgress] = [],
        removedTargetIds: [String] = [],
        removedPreferenceKeys: [String] = [],
        heldBindingIds: [String] = []
    ) {
        self.version = version
        self.actorId = actorId
        self.groupId = groupId
        self.targets = targets
        self.removedTargetIds = removedTargetIds
        self.removedPreferenceKeys = removedPreferenceKeys
        self.heldBindingIds = heldBindingIds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        actorId = try values.decode(String.self, forKey: .actorId)
        groupId = try values.decodeIfPresent(String.self, forKey: .groupId)
        targets = try values.decode([SyncTargetProgress].self, forKey: .targets)
        removedTargetIds =
            try values.decodeIfPresent([String].self, forKey: .removedTargetIds) ?? []
        removedPreferenceKeys =
            try values.decodeIfPresent([String].self, forKey: .removedPreferenceKeys) ?? []
        heldBindingIds =
            try values.decodeIfPresent([String].self, forKey: .heldBindingIds) ?? []
    }

    public var hasJoined: Bool { groupId != nil }

    /// A new phone set up from an iPhone backup gets this file, but
    /// not the Keychain items of the old phone. Automerge needs one
    /// writer per actor id, so an id that the device does not hold
    /// gives way to a fresh one. Returns whether the id changed.
    public mutating func replaceActor(
        unlessTheDeviceHolds deviceActorId: String?, fresh: () -> String
    ) -> Bool {
        guard actorId != deviceActorId else { return false }
        actorId = fresh()
        return true
    }

    public func progress(ofTarget targetId: String) -> SyncTargetProgress? {
        targets.first { $0.targetId == targetId }
    }

    public mutating func confirm(targetId: String, heads: [String]) {
        var progress =
            progress(ofTarget: targetId)
            ?? SyncTargetProgress(targetId: targetId)
        progress.confirmedHeads = heads.sorted()
        replace(progress)
    }

    public mutating func saw(
        namespaceId: String, at date: Date, sizeBytes: Int64, targetId: String
    ) {
        var progress =
            progress(ofTarget: targetId)
            ?? SyncTargetProgress(targetId: targetId)
        progress.seenNamespaces[namespaceId] = date
        progress.seenSizes[namespaceId] = sizeBytes
        replace(progress)
    }

    private mutating func replace(_ progress: SyncTargetProgress) {
        targets.removeAll { $0.targetId == progress.targetId }
        targets.append(progress)
        targets.sort { $0.targetId < $1.targetId }
    }

    /// A target that left takes its progress with it. Removing a
    /// target stays local-only, per 10.8.
    public mutating func forget(targetId: String) {
        targets.removeAll { $0.targetId == targetId }
        if !removedTargetIds.contains(targetId) {
            removedTargetIds.append(targetId)
        }
    }

    /// A target the user adds again is one this device holds once more.
    public mutating func keep(targetId: String) {
        removedTargetIds.removeAll { $0 == targetId }
    }

    /// The first device creates the group id when it adds its first
    /// target, per 10.4.
    public mutating func startAGroup() {
        guard groupId == nil else { return }
        groupId = SyncGroup.makeId()
    }

    public mutating func join(_ groupId: String) {
        self.groupId = groupId
        // The new group has its own history, so nothing this device
        // uploaded before counts as confirmed.
        targets = []
        removedPreferenceKeys = []
        heldBindingIds = []
    }

    // MARK: - The file

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    /// The saved state, or a fresh one with a new actor identity.
    public static func read(
        applicationSupport: URL, actorId: @autoclosure () -> String
    )
        -> SyncState
    {
        let url = applicationSupport.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: url),
            let state = try? decoder.decode(SyncState.self, from: data)
        else { return SyncState(actorId: actorId()) }
        return state
    }

    public func write(applicationSupport: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(
            to: applicationSupport.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
