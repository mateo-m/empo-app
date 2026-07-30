import Foundation

/// File-tree operations behind in-place game updates: merge a new
/// import over an installed tree, staged and swapped atomically.
///
/// Lives in GameProbe (not the app target) so the semantics are
/// exercised by the Linux `swift test` CI job. On Darwin,
/// `FileManager.copyItem` within one APFS volume is a
/// copy-on-write clone, so staging a multi-gigabyte game costs
/// roughly the size of the *new* files; on other platforms (tests)
/// it's a real copy, which is fine at test scale.
public enum GameTreeUpdate {

    /// Transient sibling of the target tree used by `stageAndSwap`.
    /// Dot-prefixed: hidden from library discovery and from casual
    /// Files browsing.
    public static let stagingDirectoryName = ".game-update-staging"

    /// Name `replaceItemAt` uses for the displaced original tree
    /// during the swap. Naming it explicitly (instead of letting
    /// Foundation pick an anonymous temp name) means a crash inside
    /// the swap window leaves a leftover `removeStaleArtifacts` can
    /// recognize and sweep.
    public static let backupDirectoryName = ".game-update-backup"

    /// Normalize owner-write over a tree (directories 0755, files
    /// 0644) so its entries can be overwritten or deleted.
    /// Windows-origin archives often land with read-only POSIX bits.
    public static func normalizeOwnerWritable(
        at url: URL,
        fm: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children {
                try normalizeOwnerWritable(at: child, fm: fm)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } else {
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }

    /// Move the tree at `source` into `destination`,
    /// upgrade-in-place: a file that exists at the same relative
    /// path is overwritten by the new copy (a type conflict
    /// resolves to the new entry), and anything only present in the
    /// destination stays - saves written next to the game files,
    /// mods, and assets the new version happens not to ship.
    /// Mirrors what desktop players do when they extract a new
    /// version over an existing install.
    public static func mergeMove(
        from source: URL,
        into destination: URL,
        fm: FileManager = .default
    ) throws {
        var destinationIsDir: ObjCBool = false
        let destinationExists = fm.fileExists(
            atPath: destination.path, isDirectory: &destinationIsDir)
        guard destinationExists, destinationIsDir.boolValue else {
            if destinationExists {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: source, to: destination)
            return
        }

        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let entryIsDir =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)

            if targetExists, targetIsDir.boolValue, entryIsDir {
                try mergeMove(from: entry, into: target, fm: fm)
                continue
            }
            if targetExists {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: entry, to: target)
        }

        // The source directory is an empty husk now; its removal
        // failing is harmless (it lives in the import tmp dir).
        try? fm.removeItem(at: source)
    }

    /// Transactional in-place update: build the merged tree in a
    /// staging copy next to `target`, then swap it into place
    /// atomically (`FileManager.replaceItemAt`). Failure at ANY
    /// point before the swap - a merge error, disk full - leaves
    /// the tree at `target` byte-for-byte untouched; staging
    /// leftovers are removed here, and `removeStaleArtifacts`
    /// sweeps any that a hard crash orphaned.
    public static func stageAndSwap(
        newTree source: URL,
        over target: URL,
        fm: FileManager = .default
    ) throws {
        let parent = target.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(stagingDirectoryName, isDirectory: true)
        let backup = parent.appendingPathComponent(backupDirectoryName, isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: backup)
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: backup)
        }

        try fm.copyItem(at: target, to: staging)
        // The copy carries the original's POSIX bits; normalizing
        // the staging tree (never the live one) lets the merge
        // overwrite read-only entries.
        try normalizeOwnerWritable(at: staging, fm: fm)
        try mergeMove(from: source, into: staging, fm: fm)
        _ = try fm.replaceItemAt(
            target,
            withItemAt: staging,
            backupItemName: backupDirectoryName
        )
    }

    /// Remove staging/backup leftovers from an update that a crash
    /// or force-quit interrupted. Returns the names it removed so
    /// the caller can log them.
    @discardableResult
    public static func removeStaleArtifacts(
        in parent: URL,
        fm: FileManager = .default
    ) -> [String] {
        var removed: [String] = []
        for name in [stagingDirectoryName, backupDirectoryName] {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed
    }
}
