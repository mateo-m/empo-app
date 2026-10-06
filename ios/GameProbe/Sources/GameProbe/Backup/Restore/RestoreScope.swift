import Foundation

/// What a restore covers, per SPEC 11.7.
///
/// The scope question offers two choices and no third. No per-file
/// browser ships.
///
/// The narrow choice restores exactly the members slim mode selects
/// for that game, per section 3, so one membership definition serves
/// the first-backup prompt and both restore paths.
///
/// The last two cases are not choices in that question. The
/// fresh-install screen of 11.4 lists the preferences and the
/// Rescued Saves buckets as two rows, and one preferences snapshot
/// holds both, so each row restores its own half.
public enum RestoreScope: String, Codable, Sendable, CaseIterable, Equatable {

    /// Every entry the snapshot holds.
    case wholeGame = "whole-game"

    /// The save members alone, which is what `SaveMemberRule`
    /// answers.
    case savesAndSettings = "saves-and-settings"

    /// The Rescued Saves buckets alone, per 11.4.
    case rescuedSaves = "rescued-saves"

    /// The preferences stream without its Rescued Saves buckets: the
    /// UserDefaults export and the layout profiles, per 11.4.
    case preferences

    /// Whether this scope restores one entry.
    public func covers(_ entry: SnapshotManifest.Entry) -> Bool {
        switch self {
        case .wholeGame:
            return true
        case .savesAndSettings:
            return SaveMemberRule.isSaveMember(entry)
        case .rescuedSaves:
            return entry.root == .rescuedSaves
        case .preferences:
            return entry.root != .rescuedSaves && SaveMemberRule.isSaveMember(entry)
        }
    }
}
