import Foundation

/// The record of what `PreLiteralSaveHeal` promoted, queued until
/// the library shows its one-time recovery sheet. Pure data and
/// policy: the app persists the encoded ledger (one UserDefaults
/// blob) and renders the sheet; everything a test can pin lives
/// here.
public enum SaveRecoveryLedger {

    /// One recovered directory.
    public struct Record: Codable, Equatable, Identifiable, Sendable {
        /// Display name: the game the recovery belongs to.
        /// The healed data directory's leaf in every common case
        /// (launch and per-game heals alike); the container
        /// folder name only on the per-game FALLBACK path, where
        /// the healed directory is the container's `UserData/`
        /// and its leaf would name no game.
        public let name: String
        /// The healed directory as a path relative to the app's
        /// Documents root (`"Data/Nova"`,
        /// `"Data/PKMN Essentials/Nova"`,
        /// `"Games/Nova/UserData"`). The record's identity, and
        /// what a Files-app link must open - data directories
        /// nest, so the display name alone cannot locate them.
        public let directory: String
        /// Promoted save file names, e.g. `["Game.rxdata"]`.
        public let files: [String]
        /// When the first promotion for this directory happened.
        public let date: Date

        public var id: String { directory }

        public init(name: String, directory: String, files: [String], date: Date) {
            self.name = name
            self.directory = directory
            self.files = files
            self.date = date
        }
    }

    /// Merge a heal outcome into the ledger. Repeat heals of one
    /// directory (the launch pass, then the per-game heal) fold
    /// into a single record: file lists union in first-seen order
    /// and the original date and name stay. Unchanged input comes
    /// back unchanged, so callers can skip a rewrite.
    public static func merging(
        _ records: [Record], name: String, directory: String, files: [String], date: Date
    ) -> [Record] {
        guard let index = records.firstIndex(where: { $0.directory == directory }) else {
            return records
                + [Record(name: name, directory: directory, files: files, date: date)]
        }
        let existing = records[index]
        let newFiles = files.filter { !existing.files.contains($0) }
        guard !newFiles.isEmpty else { return records }
        var merged = records
        merged[index] = Record(
            name: existing.name,
            directory: existing.directory,
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
