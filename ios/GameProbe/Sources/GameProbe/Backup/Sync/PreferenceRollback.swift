import Foundation

/// The preference rollback and its undo, per SPEC 10.9.
///
/// A rollback never rewinds history and never forks it. Empo reads
/// an older snapshot from the `prefs/` stream and applies it as new
/// changes, so every joined device receives it the ordinary way.
public enum PreferenceRollback {

    /// One confirmation states what a rollback reaches.
    public static let confirmation =
        "This changes settings on every device that joined this sync group."

    /// What the rollback writes: the snapshot's portable values, and
    /// a delete for every portable key the snapshot does not carry.
    public static func plan(
        current: [String: JSONValue], snapshot: [String: JSONValue]
    ) -> PreferenceRollbackPlan {
        let wanted = PreferenceExport.portableValues(of: snapshot)
        var sets: [String: JSONValue] = [:]
        for (key, value) in wanted where current[key] != value {
            sets[key] = value
        }
        let deletes = PreferenceExport.portableValues(of: current).keys
            .filter { wanted[$0] == nil }
            .sorted()
        return PreferenceRollbackPlan(sets: sets, deletes: deletes)
    }
}

public struct PreferenceRollbackPlan: Equatable, Sendable {

    public var sets: [String: JSONValue]
    public var deletes: [String]

    public init(sets: [String: JSONValue] = [:], deletes: [String] = []) {
        self.sets = sets
        self.deletes = deletes
    }

    public var isEmpty: Bool { sets.isEmpty && deletes.isEmpty }
}

/// The one local undo of 10.9.
///
/// Empo saves it before a rollback. The next rollback replaces it,
/// and it expires after 7 days. Undo applies as new group changes
/// too, so it is not a rewind either.
public struct PreferenceRollbackUndo: Codable, Equatable, Sendable {

    public static let currentVersion = 1
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public var version: Int
    public var savedAt: Date
    /// The portable values as they were before the rollback.
    public var values: [String: JSONValue]

    public init(
        version: Int = PreferenceRollbackUndo.currentVersion,
        savedAt: Date,
        values: [String: JSONValue]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.values = values
    }

    /// It expires after 7 days, so 7 days exactly still undoes.
    public func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(savedAt) > Self.lifetime
    }

    // MARK: - The file

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    /// The saved undo, or `nil` where none is there or it expired.
    /// An expired file is dropped as it is read.
    public static func read(
        applicationSupport: URL, at date: Date, fm: FileManager = .default
    ) -> PreferenceRollbackUndo? {
        let url = BackupRootLayout(applicationSupport: applicationSupport).preferenceRollbackFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let undo = try? decoder.decode(PreferenceRollbackUndo.self, from: data) else {
            try? fm.removeItem(at: url)
            return nil
        }
        guard !undo.isExpired(at: date) else {
            try? fm.removeItem(at: url)
            return nil
        }
        return undo
    }

    public func write(applicationSupport: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(
            to: BackupRootLayout(applicationSupport: applicationSupport).preferenceRollbackFile,
            options: .atomic)
    }

    public static func clear(applicationSupport: URL, fm: FileManager = .default) {
        try? fm.removeItem(
            at: BackupRootLayout(applicationSupport: applicationSupport).preferenceRollbackFile)
    }
}
