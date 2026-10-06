import Foundation

/// The local undo of SPEC 10.9 and 11.13,
/// `preference-rollback.json` under Application Support.
///
/// It holds the export as it stood before the restore wrote over it.
/// The next restore replaces it, and it expires after 7 days, per
/// 10.9. Ticket 015 writes the same file on the joined path.
public struct PreferenceUndoFile: Codable, Equatable, Sendable {

    public static let currentVersion = 1
    /// How long the undo stays offered, per 10.9.
    public static let expiryDays = 7

    public var version: Int
    public var savedAt: Date
    /// The export as it stood before the restore.
    public var preferences: [String: JSONValue]

    public init(
        version: Int = PreferenceUndoFile.currentVersion,
        savedAt: Date,
        preferences: [String: JSONValue]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.preferences = preferences
    }

    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(savedAt) > Double(Self.expiryDays) * 24 * 60 * 60
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> PreferenceUndoFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PreferenceUndoFile.self, from: data)
    }

    public static func read(applicationSupport: URL) -> PreferenceUndoFile? {
        let url = BackupRootLayout(applicationSupport: applicationSupport).preferenceRollbackFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(json: data)
    }

    public func write(applicationSupport: URL) throws {
        let url = BackupRootLayout(applicationSupport: applicationSupport).preferenceRollbackFile
        try jsonData().write(to: url, options: .atomic)
    }
}

/// The preferences restore of SPEC 11.13, on a device that did not
/// join a sync group.
///
/// The snapshot's exported keys are written over the local ones,
/// after Empo saves the current export as a local undo file.
/// Device-local keys and never-stored keys do not restore.
///
/// A joined device follows 10.9 instead, which is ticket 015.
///
/// The portable key list is a parameter and not a constant here. The
/// classes of 10.1 ride `DefaultsKey`, which ticket 015 owns, so this
/// planner filters against what the caller hands it and invents no
/// second list.
public enum PreferenceRestore {

    /// What one preferences restore does.
    public struct Plan: Equatable, Sendable {

        /// The keys and values to write over the local ones.
        public var write: [String: JSONValue]
        /// Keys the export carried that this device does not
        /// restore. A snapshot from a newer Empo can hold a key this
        /// build does not know.
        public var skippedKeys: [String]
        /// The undo to save before the write.
        public var undo: PreferenceUndoFile

        public init(
            write: [String: JSONValue], skippedKeys: [String], undo: PreferenceUndoFile
        ) {
            self.write = write
            self.skippedKeys = skippedKeys
            self.undo = undo
        }
    }

    /// Plans the write.
    ///
    /// - `exported`: the keys the snapshot's export holds.
    /// - `localExport`: the current export, which becomes the undo.
    /// - `portableKeys`: the keys of the portable class of 10.1.
    ///   Anything else in the export is skipped, whichever class it
    ///   belongs to.
    public static func plan(
        exported: [String: JSONValue],
        localExport: [String: JSONValue],
        portableKeys: Set<String>,
        at date: Date
    ) -> Plan {
        var write: [String: JSONValue] = [:]
        var skipped: [String] = []
        for (key, value) in exported {
            if portableKeys.contains(key) {
                write[key] = value
            } else {
                skipped.append(key)
            }
        }
        return Plan(
            write: write,
            skippedKeys: skipped.sorted(),
            undo: PreferenceUndoFile(savedAt: date, preferences: localExport))
    }

    /// The one undo affordance of 11.13.
    public static let undoLabel = "Undo this settings restore"

    /// The line the confirmation carries.
    public static let confirmationLine =
        "This puts back the settings from this backup. You can undo it for 7 days."
}
