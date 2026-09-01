import Foundation

/// Where each file sits inside a backup package, per SPEC 12.2.
///
/// Files keep their original paths, relative to `Documents/`. A
/// reader with no Empo opens the ZIP and sees the tree the device
/// holds, which is the whole point of the format.
public enum PackageLayout {

    public static let manifestPath = "manifest.json"
    public static let readmePath = "README.txt"
    public static let documentsPrefix = "Documents/"
    public static let gamesPrefix = "Documents/Games/"
    public static let profilesPrefix = "Documents/Profiles/"
    public static let rescuedSavesPrefix = "Documents/Rescued Saves/"
    /// `UserDefaults` has no file path, so the export takes one, per
    /// 12.2.
    public static let preferencesPath = "Preferences/defaults.json"
    /// Where the shared data of 4.5 goes when the manifest names no
    /// directory for it.
    public static let dataPrefix = "Documents/Data/"

    /// The path one manifest entry takes in the ZIP, or `nil` where
    /// the manifest holds no root for it.
    public static func zipPath(
        of entry: SnapshotManifest.Entry, in manifest: SnapshotManifest
    ) -> String? {
        switch entry.root {
        case .container:
            guard !manifest.containerFolderName.isEmpty else { return nil }
            return gamesPrefix + manifest.containerFolderName + "/" + entry.path
        case .sharedData:
            return sharedPrefix(manifest.sharedDataDirectory) + entry.path
        case .rescuedSaves:
            return rescuedSavesPrefix + entry.path
        case .preferences:
            return preferencesZipPath(entry.path)
        }
    }

    /// The header records the shared directory relative to
    /// `Documents/`, per 4.5. An older header that fell back to the
    /// absolute path keeps its last component under `Documents/`,
    /// because the absolute one holds an app-container id no second
    /// device can rebuild.
    private static func sharedPrefix(_ recorded: String?) -> String {
        guard let recorded, !recorded.isEmpty else { return dataPrefix }
        guard recorded.hasPrefix("/") else {
            return documentsPrefix + trimmed(recorded) + "/"
        }
        let name = URL(fileURLWithPath: recorded).lastPathComponent
        return dataPrefix + name + "/"
    }

    private static func preferencesZipPath(_ path: String) -> String? {
        if path == BackupSetResolver.userDefaultsExportPathName { return preferencesPath }
        let profiles = BackupSetResolver.profilesPathPrefix + "/"
        if path.hasPrefix(profiles) {
            return profilesPrefix + String(path.dropFirst(profiles.count))
        }
        let rescued = BackupSetResolver.rescuedSavesPathPrefix + "/"
        if path.hasPrefix(rescued) {
            return rescuedSavesPrefix + String(path.dropFirst(rescued.count))
        }
        return nil
    }

    private static func trimmed(_ path: String) -> String {
        var out = path
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    // MARK: - The file name, per 12.1

    /// `<game>-Empo-backup-<YYYY-MM-DD>.zip`, or the library name
    /// when `gameName` is `nil`. Files handles a name collision.
    public static func fileName(gameName: String?, date: Date) -> String {
        let day = dayText(date)
        guard let gameName else { return "Empo-library-backup-\(day).zip" }
        return "\(safeName(gameName))-Empo-backup-\(day).zip"
    }

    static func dayText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// A file name a file system takes. It keeps the game's own
    /// name where it can, because the user reads it in Files.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            "/\\:?%*|\"<>".contains(character) ? "-" : character
        }
        let out = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "Game" : String(out.prefix(80))
    }

    // MARK: - README.txt, per 12.2

    public static let readmeText = """
        This ZIP file is an Empo backup package.

        What is in it
        -------------
        Documents/       the files as this device holds them.
          Games/         one folder for each game. Save files are in
                         the game folder, usually in Game/ beside the
                         game data.
          Data/          data that games share.
          Profiles/      touch control layouts.
          Rescued Saves/ save files Empo found outside a game.
        Preferences/     app settings as JSON. iOS keeps settings in a
                         database with no file path, so they get one
                         here.
        manifest.json    what each file is, how large it is, and its
                         SHA-256 hash.

        How to use it
        -------------
        Empo can import this file. Open Empo, go to Backups, and use
        "Import backup".

        You can also open this ZIP with any tool and copy the files
        yourself. Another launcher keeps its saves in a different
        place, so you may have to put each file where that launcher
        looks for it. Empo gives you an open format. It does not
        convert the files for another launcher.
        """
}
