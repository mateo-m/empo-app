import Foundation

/// The stable identity of each layout profile, per SPEC 10.3 and
/// 10.6.
///
/// A profile is a folder named by the user, and a name is not an
/// identity: two devices may hold different profiles under one name,
/// and recreating a deleted profile must not bring the old one back.
/// This file keeps the map from the local folder name to the id the
/// document uses.
///
/// It sits beside the backup root, not inside it, because Empo may
/// delete the root whole. Losing the map would make every profile
/// look new to the group.
public struct SyncProfileIdentities: Codable, Equatable, Sendable {

    public static let currentVersion = 1
    public static let fileName = "sync-profile-ids.json"

    public var version: Int
    /// Profile folder name -> identity.
    public var ids: [String: String]
    /// Identity -> when this device deleted the profile. The pass
    /// carries it into the document as the deletion record of 10.6,
    /// and it stays here so a second pass does not resurrect the
    /// profile.
    public var deleted: [String: Date]

    public init(
        version: Int = SyncProfileIdentities.currentVersion,
        ids: [String: String] = [:],
        deleted: [String: Date] = [:]
    ) {
        self.version = version
        self.ids = ids
        self.deleted = deleted
    }

    public static func makeId() -> String {
        BackupKeys.randomHex(characters: 16)
    }

    /// The identity of one profile, minted on the first ask.
    public mutating func id(ofProfile name: String) -> String {
        if let known = ids[name] { return known }
        let fresh = Self.makeId()
        ids[name] = fresh
        return fresh
    }

    public func knownId(ofProfile name: String) -> String? {
        ids[name]
    }

    public func name(ofId id: String) -> String? {
        ids.first { $0.value == id }?.key
    }

    /// A rename keeps the identity, so the group sees one profile
    /// under a new name.
    public mutating func rename(from oldName: String, to newName: String) {
        guard let id = ids.removeValue(forKey: oldName) else { return }
        ids[newName] = id
    }

    /// A local delete drops the identity and keeps the record. The
    /// record is what beats a concurrent offline edit, and
    /// recreating the profile mints a new identity, per 10.6.
    public mutating func markDeleted(profile name: String, at date: Date) {
        guard let id = ids.removeValue(forKey: name) else { return }
        deleted[id] = date
    }

    /// A delete this device applied from the document. The document
    /// already carries the record, so nothing is added here.
    public mutating func forget(profile name: String) {
        ids.removeValue(forKey: name)
    }

    // MARK: - The file

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func read(applicationSupport: URL) -> SyncProfileIdentities {
        let url = applicationSupport.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: url),
            let file = try? decoder.decode(SyncProfileIdentities.self, from: data)
        else { return SyncProfileIdentities() }
        return file
    }

    public func write(applicationSupport: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(
            to: applicationSupport.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
