import Foundation

/// File-tree operations behind in-place game updates: merge a new
/// import over an installed tree, staged and swapped atomically.
///
/// Lives in GameProbe (not the app target) so the semantics are
/// exercised by the Linux `swift test` CI job. On Darwin,
/// `FileManager.copyItem` within one APFS volume is a
/// copy-on-write clone, so staging a multi-gigabyte game costs
/// roughly the size of the *new* files. On other platforms (tests)
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
        // Never follow symlinks: `setAttributes` resolves them, so
        // a link inside an imported tree would chmod its TARGET -
        // which a hostile archive can point anywhere the sandbox
        // reaches. Links keep their own permissions.
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
            type == .typeSymbolicLink
        {
            return
        }
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
    ///
    /// `protecting` names root entries of `destination` that hold
    /// player data (portable saves). A collision on a protected
    /// entry never discards a byte: it follows the drain rules
    /// instead of plain overwrite (see `mergeProtected`). Names
    /// match case-insensitively, so an archive with a case-variant
    /// name cannot slip past the protection on a case-insensitive
    /// volume.
    public static func mergeMove(
        from source: URL,
        into destination: URL,
        protecting protectedNames: Set<String> = [],
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

        let protectedLowered = Set(protectedNames.map { $0.lowercased() })
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            let name = entry.lastPathComponent
            let target = destination.appendingPathComponent(name)
            let entryIsDir =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)

            if targetExists, protectedLowered.contains(name.lowercased()) {
                try mergeProtected(
                    entry: entry, entryIsDir: entryIsDir,
                    target: target, targetIsDir: targetIsDir.boolValue, fm: fm)
                continue
            }
            if targetExists, targetIsDir.boolValue, entryIsDir {
                try mergeMove(from: entry, into: target, fm: fm)
                continue
            }
            if targetExists {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: entry, to: target)
        }

        // The source directory is an empty husk now. Its removal
        // failing is harmless (it lives in the import tmp dir).
        try? fm.removeItem(at: source)
    }

    /// Collision handling for a protected (portable-save) entry,
    /// with the same rules as `LegacyDataDrain`: same-named
    /// directories merge per file, the newer file wins the
    /// canonical name (ties go to the incoming file), and the loser
    /// stays beside it as `<name>.empo-displaced[-N].bak`. A type
    /// conflict keeps the installed entry - it is the one the game
    /// currently reads - and displaces the incoming entry whole.
    /// An imported archive can therefore never destroy a player's
    /// save, and a deliberate save transfer inside an update
    /// archive still lands.
    private static func mergeProtected(
        entry: URL, entryIsDir: Bool,
        target: URL, targetIsDir: Bool,
        fm: FileManager
    ) throws {
        if entryIsDir, targetIsDir {
            let children = try fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            for child in children {
                let childTarget = target.appendingPathComponent(child.lastPathComponent)
                let childIsDir =
                    (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                var childTargetIsDir: ObjCBool = false
                guard fm.fileExists(atPath: childTarget.path, isDirectory: &childTargetIsDir)
                else {
                    try fm.moveItem(at: child, to: childTarget)
                    continue
                }
                try mergeProtected(
                    entry: child, entryIsDir: childIsDir,
                    target: childTarget, targetIsDir: childTargetIsDir.boolValue, fm: fm)
            }
            if (try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty == true {
                try? fm.removeItem(at: entry)
            }
            return
        }
        if entryIsDir != targetIsDir {
            try displaceIncoming(entry, near: target, fm: fm)
            return
        }
        // A byte-identical incoming file adds nothing: drop it
        // instead of stacking a duplicate displaced copy.
        if FileContentEquality.identical(entry, target, fm: fm) {
            try fm.removeItem(at: entry)
            return
        }
        if modificationDate(of: entry, fm: fm) >= modificationDate(of: target, fm: fm) {
            let archived = displacedURL(near: target, fm: fm)
            try fm.moveItem(at: target, to: archived)
            try fm.moveItem(at: entry, to: target)
        } else {
            try displaceIncoming(entry, near: target, fm: fm)
        }
    }

    private static func displaceIncoming(
        _ entry: URL, near target: URL, fm: FileManager
    ) throws {
        try fm.moveItem(at: entry, to: displacedURL(near: target, fm: fm))
    }

    private static func displacedURL(near target: URL, fm: FileManager) -> URL {
        let name = target.lastPathComponent
        return UniqueFileName.firstAvailableURL(
            in: target.deletingLastPathComponent(),
            preferring: LegacyDataDrain.displacedName(for: name),
            numbered: { LegacyDataDrain.displacedName(for: name, index: $0) },
            fm: fm
        )
    }

    private static func modificationDate(of url: URL, fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Transactional in-place update: build the merged tree in a
    /// staging copy next to `target`, then swap it into place
    /// (`FileManager.replaceItemAt`). Portable saves detected in
    /// the installed tree are protected during the merge - a
    /// colliding entry in the archive cannot delete them (see
    /// `mergeProtected`). Failure at ANY point before
    /// the swap - a merge error, disk full - leaves the tree at
    /// `target` byte-for-byte untouched. A failure DURING the swap
    /// can leave no tree at `target` (Foundation documents that a
    /// failed replace may strand the original at a temporary
    /// location), so the failure path restores from the surviving
    /// artifacts before it cleans anything up. Artifacts a hard
    /// crash orphaned are handled by `sweepInterruptedUpdate`.
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

        do {
            try fm.copyItem(at: target, to: staging)
            // The copy carries the original's POSIX bits.
            // Normalizing the staging tree lets the merge overwrite
            // read-only entries.
            try normalizeOwnerWritable(at: staging, fm: fm)
            let saveEntries = Set(PortableGameSaves.entryNames(atGameRoot: staging, fm: fm))
            try mergeMove(from: source, into: staging, protecting: saveEntries, fm: fm)
            // The original tree becomes the swap's backup and is
            // deleted as part of the swap - normalize it too so
            // read-only bits can't fail the swap after the exchange
            // already happened (or block the stale sweep after a
            // crash). Metadata-only and the merge has already
            // succeeded, so this can no longer strand a half-update.
            try normalizeOwnerWritable(at: target, fm: fm)
            try swapStagedTree(target: target, staging: staging, backup: backup, fm: fm)
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: backup)
        } catch {
            // Never sweep blind on failure: after a failed swap the
            // staging and backup trees can be the only copies of
            // the game. Put a tree back at `target` first, then
            // remove only what is genuinely redundant. The BACKUP
            // (pre-update tree) is preferred here, unlike crash
            // recovery: this update is FAILING, and promoting the
            // merged staging tree would install the new files
            // behind a failure report, with finalize never run -
            // a stale script profile over a tree the user was told
            // did not apply.
            if !healthyTreeExists(at: target, fm: fm) {
                restoreFromDisplacedOriginal(error: error, target: target, fm: fm)
            }
            _ = restoreMissingTarget(
                target: target, parent: parent,
                preferring: [backupDirectoryName, stagingDirectoryName], fm: fm)
            if healthyTreeExists(at: target, fm: fm) {
                try? fm.removeItem(at: staging)
                try? fm.removeItem(at: backup)
            }
            throw error
        }
    }

    /// Swap the merged staging tree into place. Darwin's
    /// `replaceItemAt` performs the exchange natively. On Linux,
    /// swift-corelibs-foundation implements the replace as a rename
    /// onto the existing directory, and the kernel rejects that
    /// with ENOTEMPTY. Perform the same exchange manually there:
    /// the original moves to the backup name first, then the
    /// staging tree takes its place. The artifact names match what
    /// `sweepInterruptedUpdate` and the failure path expect.
    private static func swapStagedTree(
        target: URL, staging: URL, backup: URL, fm: FileManager
    ) throws {
        #if canImport(Darwin)
            _ = try fm.replaceItemAt(
                target,
                withItemAt: staging,
                backupItemName: backupDirectoryName
            )
        #else
            try fm.moveItem(at: target, to: backup)
            do {
                try fm.moveItem(at: staging, to: target)
            } catch {
                // Put the original back so the catch in
                // `stageAndSwap` sees a healthy tree and only
                // removes genuinely redundant artifacts.
                try? fm.moveItem(at: backup, to: target)
                throw error
            }
        #endif
    }

    private static func healthyTreeExists(at target: URL, fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: target.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A failed `replaceItemAt` may leave the original item at a
    /// temporary location, recorded in the error's
    /// `NSFileOriginalItemLocationKey`. Move it home when the
    /// target is empty. Key looked up by name: the constant is not
    /// exposed uniformly across Foundation implementations.
    private static func restoreFromDisplacedOriginal(
        error: Error, target: URL, fm: FileManager
    ) {
        let userInfo = (error as NSError).userInfo
        let displaced =
            (userInfo["NSFileOriginalItemLocationKey"] as? URL)
            ?? (userInfo["NSFileOriginalItemLocationKey"] as? String)
            .map { URL(fileURLWithPath: $0) }
        guard let displaced, displaced.path != target.path,
            fm.fileExists(atPath: displaced.path)
        else { return }
        try? fm.moveItem(at: displaced, to: target)
    }

    /// Shared restore step: when no directory sits at `target`, move
    /// the best surviving artifact into place, in the caller's
    /// preference order. Crash recovery prefers staging (fully
    /// merged - the swap only starts after the merge completes).
    /// The in-flight failure path prefers the backup (see the
    /// catch in `stageAndSwap`). A stray non-directory at `target`
    /// (a crash artifact of unknown origin) is moved aside first,
    /// but only when an artifact exists to restore - otherwise the
    /// file, whatever it is, stays untouched.
    private static func restoreMissingTarget(
        target: URL, parent: URL,
        preferring order: [String] = [stagingDirectoryName, backupDirectoryName],
        fm: FileManager
    ) -> String? {
        let candidates = order.filter {
            fm.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
        guard !candidates.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            let aside = parent.appendingPathComponent(
                target.lastPathComponent + ".empo-unexpected")
            try? fm.removeItem(at: aside)
            try? fm.moveItem(at: target, to: aside)
        }
        guard !fm.fileExists(atPath: target.path) else { return nil }

        for candidate in candidates {
            let url = parent.appendingPathComponent(candidate, isDirectory: true)
            if (try? fm.moveItem(at: url, to: target)) != nil {
                return candidate
            }
        }
        return nil
    }

    /// Outcome of `sweepInterruptedUpdate`, for caller logging.
    public struct SweepOutcome: Equatable, Sendable {
        /// Artifact name the missing target tree was restored from,
        /// or nil when no restore was needed (or possible).
        public let restoredFrom: String?
        /// Artifact names removed after any restore.
        public let removed: [String]
    }

    /// Crash recovery for `stageAndSwap`. Apple documents no
    /// internal sequence for `replaceItemAt`, only that a failure
    /// can leave the original away from its home. A kill mid-swap
    /// can therefore leave NO tree at `target` while the artifacts
    /// survive. Sweeping blindly at that point would destroy the
    /// only copies of the game, so this restores first (staging
    /// wins, backup is the fallback - see `restoreMissingTarget`),
    /// and only then removes the remaining artifacts. A stray
    /// non-directory at `target` does not count as a healthy tree.
    /// With a healthy target this is a plain sweep.
    @discardableResult
    public static func sweepInterruptedUpdate(
        target: URL,
        fm: FileManager = .default
    ) -> SweepOutcome {
        let parent = target.deletingLastPathComponent()
        var restoredFrom: String?

        if !healthyTreeExists(at: target, fm: fm) {
            restoredFrom = restoreMissingTarget(target: target, parent: parent, fm: fm)
        }

        // Do not sweep while the target is still missing: a restore
        // that failed (permissions, exotic filesystems) must leave
        // the artifacts in place for the next attempt.
        guard healthyTreeExists(at: target, fm: fm) else {
            return SweepOutcome(restoredFrom: restoredFrom, removed: [])
        }
        return SweepOutcome(
            restoredFrom: restoredFrom,
            removed: removeStaleArtifacts(in: parent, fm: fm)
        )
    }

    /// Remove staging/backup leftovers. Callers recovering from a
    /// possible crash must use `sweepInterruptedUpdate` instead,
    /// which restores a missing target tree before sweeping.
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
