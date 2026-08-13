import Foundation

/// The record of what `PreLiteralSaveHeal` promoted, queued until
/// the library shows its one-time recovery sheet. Pure data and
/// policy: the app persists the encoded ledger (one UserDefaults
/// blob) and renders the sheet; everything a test can pin lives
/// here.
public enum SaveRecoveryLedger {

    /// One recovered data directory.
    public struct Record: Codable, Equatable, Identifiable, Sendable {
        /// The data-directory name under the shared data root
        /// (the INI title for almost every game).
        public let name: String
        /// Promoted save file names, e.g. `["Game.rxdata"]`.
        public let files: [String]
        /// When the first promotion for this name happened.
        public let date: Date

        public var id: String { name }

        public init(name: String, files: [String], date: Date) {
            self.name = name
            self.files = files
            self.date = date
        }
    }

    /// Merge a heal outcome into the ledger. Repeat heals of one
    /// directory (the launch pass, then the per-game heal) fold
    /// into a single record: file lists union in first-seen order
    /// and the original date stays. Unchanged input comes back
    /// unchanged, so callers can skip a rewrite.
    public static func merging(
        _ records: [Record], name: String, files: [String], date: Date
    ) -> [Record] {
        guard let index = records.firstIndex(where: { $0.name == name }) else {
            return records + [Record(name: name, files: files, date: date)]
        }
        let existing = records[index]
        let newFiles = files.filter { !existing.files.contains($0) }
        guard !newFiles.isEmpty else { return records }
        var merged = records
        merged[index] = Record(
            name: existing.name,
            files: existing.files + newFiles,
            date: existing.date
        )
        return merged
    }

    /// Encoding is deterministic (sorted keys) so equal ledgers
    /// produce equal blobs.
    public static func encode(_ records: [Record]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }

    /// A missing or undecodable blob reads as an empty ledger: the
    /// sheet then simply does not show, and the next heal writes a
    /// fresh one.
    public static func decode(_ data: Data?) -> [Record] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }
}
