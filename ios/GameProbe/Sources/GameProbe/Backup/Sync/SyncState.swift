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
    public var joinedAt: Date?
    /// What each target confirmed, per 10.5 step 6.
    public var targets: [SyncTargetProgress]

    public init(
        version: Int = SyncState.currentVersion,
        actorId: String,
        groupId: String? = nil,
        joinedAt: Date? = nil,
        targets: [SyncTargetProgress] = []
    ) {
        self.version = version
        self.actorId = actorId
        self.groupId = groupId
        self.joinedAt = joinedAt
        self.targets = targets
    }

    public var hasJoined: Bool { groupId != nil }

    public func progress(ofTarget targetId: String) -> SyncTargetProgress? {
        targets.first { $0.targetId == targetId }
    }

    public mutating func confirm(targetId: String, heads: [String]) {
        var progress = progress(ofTarget: targetId)
            ?? SyncTargetProgress(targetId: targetId)
        progress.confirmedHeads = heads.sorted()
        replace(progress)
    }

    public mutating func saw(namespaceId: String, at date: Date, targetId: String) {
        var progress = progress(ofTarget: targetId)
            ?? SyncTargetProgress(targetId: targetId)
        progress.seenNamespaces[namespaceId] = date
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
    }

    /// The first device creates the group id when it adds its first
    /// target, per 10.4.
    public mutating func startAGroup(at date: Date) {
        guard groupId == nil else { return }
        groupId = SyncGroup.makeId()
        joinedAt = date
    }

    public mutating func join(_ groupId: String, at date: Date) {
        self.groupId = groupId
        self.joinedAt = date
        // The new group has its own history, so nothing this device
        // uploaded before counts as confirmed.
        targets = []
    }

    // MARK: - The file

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    /// The saved state, or a fresh one with a new actor identity.
    public static func read(applicationSupport: URL, actorId: @autoclosure () -> String)
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
