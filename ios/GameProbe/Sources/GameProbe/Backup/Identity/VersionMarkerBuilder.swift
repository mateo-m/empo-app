import Foundation

/// The version marker of SPEC 4.4, and the one restore it warns
/// before.
///
/// Three cheap parts: the hash of the INI bytes, the JGP
/// `manifestVersion` when the import was a JoiPlay archive, and the
/// game tree's file count with its total size. No part of it enters
/// game identity, per 4.4, so a game that updates itself keeps one
/// identity.
public enum VersionMarkerBuilder {

    /// The marker of the tree at `gameDirectory`, which is the
    /// container's `Game/` directory.
    ///
    /// `jgpManifestVersion` comes from the import. The app reads it
    /// from `Metadata/metadata.json`, and it is `nil` for every
    /// import that was not a JGP archive.
    ///
    /// The count and the size skip the files 3.2 keeps out of both
    /// modes. A displaced copy a restore left behind, or a font the
    /// user dropped in, would otherwise move the marker and warn
    /// about game files nobody changed.
    public static func make(
        gameDirectory: URL,
        jgpManifestVersion: String? = nil,
        fm: FileManager = .default
    ) -> SnapshotManifest.VersionMarker {
        var count = 0
        var total: Int64 = 0
        for file in BackupSetResolver.files(under: gameDirectory, fm: fm) {
            let containerRelative = "\(BackupSetRules.gameDirectoryName)/\(file.path)"
            guard !BackupSetRules.isAlwaysOut(containerRelativePath: containerRelative) else {
                continue
            }
            count += 1
            total += file.size
        }

        return SnapshotManifest.VersionMarker(
            gameINIHash: iniHash(gameDirectory: gameDirectory, fm: fm),
            jgpManifestVersion: jgpManifestVersion,
            fileCount: count,
            totalSize: total)
    }

    /// The hash of the INI bytes, per 4.4.
    ///
    /// The file is the one `GameINI` reads the title from: `Game.ini`
    /// when the game ships one, and the first other `*.ini` in
    /// sorted order otherwise. Pokémon Uranium ships `Uranium.ini`,
    /// so the name alone cannot find it.
    public static func iniHash(gameDirectory: URL, fm: FileManager = .default) -> String? {
        guard let ini = GameINI.iniFileURLs(at: gameDirectory, fm: fm).first else { return nil }
        return try? ContentHash.hexOfFile(at: ini)
    }

    /// Whether a restore warns before it writes, per 4.4.
    ///
    /// One case only: a full-mode restore over a tree whose marker
    /// differs, because that can bury a self-updated game under its
    /// own older files. A restore of saves and settings never warns,
    /// and no mismatch ever refuses a restore.
    ///
    /// Ticket 014 builds the sheet. Section 11.10 holds its copy.
    public static func warnsBeforeRestore(
        mode: BackupMode,
        snapshot: SnapshotManifest.VersionMarker,
        local: SnapshotManifest.VersionMarker
    ) -> Bool {
        mode == .full && snapshot != local
    }
}
