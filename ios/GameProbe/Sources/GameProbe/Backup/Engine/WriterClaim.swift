import Foundation

/// `writer.json`, the claim of SPEC 5.12.
///
/// A device reads it before any write and before any prune. Dumb
/// remotes give no compare-and-swap, so Empo detects a second writer
/// and never pretends to hold a lock.
public struct WriterClaim: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var version: Int
    /// The namespace this claim covers.
    public var namespaceId: String
    /// The install that writes it. It is not the device's serial and
    /// it names no account, per 5.7.
    public var deviceId: String
    /// The name the restore picker shows for the abandoned
    /// namespace, per 5.12.
    public var deviceName: String
    public var claimedAt: Date

    public init(
        version: Int = WriterClaim.currentVersion,
        namespaceId: String,
        deviceId: String,
        deviceName: String,
        claimedAt: Date
    ) {
        self.version = version
        self.namespaceId = namespaceId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.claimedAt = claimedAt
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> WriterClaim {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WriterClaim.self, from: data)
    }
}

/// `device.json`, per SPEC 5.1 and 5.12.
///
/// It stays a separate object from `writer.json`. The claim changes
/// almost never, and this file changes every run. Merging them would
/// rewrite the file that protects another device's data on every
/// routine run.
public struct DeviceRecord: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var version: Int
    public var deviceId: String
    public var model: String
    public var name: String
    public var lastWriteAt: Date
    /// The sync group this device joined, per 10.4. It is absent on
    /// a device that never joined, and a second device reads it here
    /// to discover the group.
    public var syncGroupId: String?
    /// When this device last saved its copy of the sync document.
    /// The join picker of 10.4 names it beside the device.
    public var syncUpdatedAt: Date?

    public init(
        version: Int = DeviceRecord.currentVersion,
        deviceId: String,
        model: String,
        name: String,
        lastWriteAt: Date,
        syncGroupId: String? = nil,
        syncUpdatedAt: Date? = nil
    ) {
        self.version = version
        self.deviceId = deviceId
        self.model = model
        self.name = name
        self.lastWriteAt = lastWriteAt
        self.syncGroupId = syncGroupId
        self.syncUpdatedAt = syncUpdatedAt
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> DeviceRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DeviceRecord.self, from: data)
    }
}

/// What the claim read tells the run to do, per SPEC 5.12.
public enum WriterClaimDecision: Equatable, Sendable {
    /// No claim is there. Write ours and carry on. A namespace is
    /// created lazily at the first write, per 5.2.
    case claim
    /// The claim is ours.
    case proceed
    /// The claim names another device. Stop and ask.
    case conflict(WriterClaim)
}

/// What the user chose after a mismatch, per SPEC 5.12.
public enum WriterClaimResolution: String, Equatable, Sendable, CaseIterable {
    /// Write to a new namespace from now on. This is the default.
    /// The abandoned namespace keeps its snapshots and stays
    /// restorable.
    case split
    /// Claim the namespace and keep writing into it.
    case takeOver = "take-over"
}

/// The claim rule of SPEC 5.12, as a pure function.
public enum WriterClaimCheck {

    /// What a run does with the claim it read.
    ///
    /// The namespace id is part of the test as well as the device
    /// id. A claim that names this device but another namespace
    /// belongs to a namespace this run is not writing, so it is not
    /// this run's claim.
    public static func decide(
        found: WriterClaim?, deviceId: String, namespaceId: String
    ) -> WriterClaimDecision {
        guard let found else { return .claim }
        guard found.deviceId == deviceId, found.namespaceId == namespaceId else {
            return .conflict(found)
        }
        return .proceed
    }

    /// The line the Backups screen shows after a split, per 7.11.
    /// The split is not a failure and it never notifies.
    public static let splitLine =
        "another device was using this backup location. "
        + "New snapshots go to a new space, and both keep their history."
}
