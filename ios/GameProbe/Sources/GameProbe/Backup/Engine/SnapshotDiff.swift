import Foundation

/// What earns a snapshot, per SPEC 7.7, as pure rules.
///
/// Content decides. There is no clock debounce and no per-day cap.
/// The engine enumerates the game's backup set, filters by size and
/// mtime against the previous manifest, and hashes only the files
/// that differ.
public enum SnapshotDiff {

    /// Which members this run must hash, and which entries it
    /// carries over from the previous manifest untouched.
    public struct Plan: Equatable, Sendable {
        /// The members whose size or mtime differs from the previous
        /// manifest, plus every member the previous manifest marked
        /// partial.
        public var changed: [BackupSetMember]
        /// The entries the previous manifest already proved, reused
        /// as they are. Their blobs are already on the target.
        public var reused: [SnapshotManifest.Entry]

        public init(changed: [BackupSetMember] = [], reused: [SnapshotManifest.Entry] = []) {
            self.changed = changed
            self.reused = reused
        }
    }

    /// The key an entry and a member match on.
    static func key(root: EntryRoot, path: String) -> String {
        "\(root.rawValue)/\(path)"
    }

    /// Whether two modified times are the same one.
    ///
    /// The manifest records a time in milliseconds, per 5.5, and the
    /// filesystem reports one in nanoseconds. A comparison at the
    /// finer precision would call every file changed on every run,
    /// because the time the previous manifest carries came back
    /// through the manifest. So the filter compares at the precision
    /// the manifest holds.
    static func sameModifiedTime(_ left: Date, _ right: Date) -> Bool {
        milliseconds(left) == milliseconds(right)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Splits the backup set into the files this run hashes and the
    /// entries it reuses.
    ///
    /// A path the previous manifest marked partial always hashes
    /// again, per 5.9: the path retries on the next run.
    public static func plan(
        members: [BackupSetMember], previous: SnapshotManifest?
    ) -> Plan {
        var known: [String: SnapshotManifest.Entry] = [:]
        for entry in previous?.entries ?? [] where !entry.partial {
            known[key(root: entry.root, path: entry.path)] = entry
        }

        var plan = Plan()
        for member in members {
            guard let entry = known[key(root: member.root, path: member.path)],
                entry.size == member.size,
                sameModifiedTime(entry.modifiedAt, member.modifiedAt)
            else {
                plan.changed.append(member)
                continue
            }
            // The detection source can move without the bytes
            // moving, and 7.2 reads it, so the reused entry takes
            // this run's label.
            var reused = entry
            reused.detectionSource = member.detectionSource
            plan.reused.append(reused)
        }
        return plan
    }

    /// Whether this run writes a snapshot at all, per 7.7.
    ///
    /// The test is the entry set: a new hash, a path that arrived,
    /// or a path that left. A file whose mtime moved while its bytes
    /// stayed the same earns nothing, because content decides.
    public static func earnsSnapshot(
        entries: [SnapshotManifest.Entry], previous: SnapshotManifest?
    ) -> Bool {
        guard let previous else { return !entries.isEmpty }
        var before: [String: SnapshotManifest.Entry] = [:]
        for entry in previous.entries {
            before[key(root: entry.root, path: entry.path)] = entry
        }
        guard before.count == entries.count else { return true }
        for entry in entries {
            guard let old = before[key(root: entry.root, path: entry.path)] else { return true }
            if old.hash != entry.hash || old.partial != entry.partial { return true }
        }
        return false
    }
}
