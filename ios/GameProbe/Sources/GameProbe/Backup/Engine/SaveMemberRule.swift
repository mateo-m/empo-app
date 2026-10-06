import Foundation

/// Which members of a backup set are saves, per SPEC 6.4 and 7.2.
///
/// Two rules read it, and both need the same answer:
///
/// - Rule 1 of 6.4 stages save members only, never the whole tree.
///   No game runs during staging, so graphics, audio, and the
///   executable hash and upload in place from the game tree.
/// - Section 7.2 resets the staleness clock only when no partial
///   path is a save member, because the promise is about saves.
public enum SaveMemberRule {

    public static func isSaveMember(
        root: EntryRoot, path: String, detectionSource: DetectionSource?
    ) -> Bool {
        switch root {
        case .sharedData, .rescuedSaves, .preferences:
            // The shared data directory and the Rescued Saves
            // buckets are save members whole, per 4.5. The stream
            // that belongs to no game holds the layout profiles and
            // the UserDefaults export, and 3.1 puts both in.
            return true
        case .container:
            if detectionSource != nil { return true }
            return BackupSetRules.isAlwaysIn(containerRelativePath: path)
        }
    }

    public static func isSaveMember(_ member: BackupSetMember) -> Bool {
        isSaveMember(
            root: member.root, path: member.path, detectionSource: member.detectionSource)
    }

    public static func isSaveMember(_ entry: SnapshotManifest.Entry) -> Bool {
        isSaveMember(root: entry.root, path: entry.path, detectionSource: entry.detectionSource)
    }
}
