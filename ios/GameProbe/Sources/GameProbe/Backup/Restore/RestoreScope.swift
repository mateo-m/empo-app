import Foundation

/// What a restore covers, per SPEC 11.7.
///
/// There are two choices and no third. No per-file browser ships.
///
/// The narrow choice restores exactly the members slim mode selects
/// for that game, per section 3, so one membership definition serves
/// the first-backup prompt and both restore paths.
public enum RestoreScope: String, Codable, Sendable, CaseIterable, Equatable {

    /// Every entry the snapshot holds.
    case wholeGame = "whole-game"

    /// The save members alone, which is what `SaveMemberRule`
    /// answers.
    case savesAndSettings = "saves-and-settings"

    /// Whether this scope restores one entry.
    public func covers(_ entry: SnapshotManifest.Entry) -> Bool {
        switch self {
        case .wholeGame:
            return true
        case .savesAndSettings:
            return SaveMemberRule.isSaveMember(entry)
        }
    }
}
