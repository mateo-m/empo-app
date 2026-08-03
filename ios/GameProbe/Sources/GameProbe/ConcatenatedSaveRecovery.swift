import Foundation

/// Recovery for the v0.2.1 `System.data_directory` regression: the
/// path briefly lacked its trailing slash, so games concatenating
/// `dir + filename` wrote saves named `UserDataGame.rxdata` at the
/// container root. Pure logic in GameProbe so the Linux CI tests
/// exercise it; `SaveMigration` in the app target drives it.
public enum ConcatenatedSaveRecovery {

    /// Marker inserted into backup names while recovering. Not a
    /// PE/RGSS save slot. Games ignore these files.
    public static let backupMarker = "empo-path-regression"

    /// `UserDataGame.rxdata` -> `Game.rxdata`; nil when the name is
    /// not a concatenation artifact. The prefix match is
    /// case-sensitive on purpose: the regression always produced
    /// the literal `UserData` prefix. A remainder starting with a
    /// dot is rejected - `UserData.rxdata` would otherwise recover
    /// into a hidden file no game can list.
    public static func remainder(ofConcatenatedName filename: String) -> String? {
        let prefix = "UserData"
        guard filename.hasPrefix(prefix) else { return nil }
        let remainder = String(filename.dropFirst(prefix.count))
        guard !remainder.isEmpty, !remainder.hasPrefix("."),
            isSaveFilename(remainder)
        else { return nil }
        return remainder
    }

    /// `Game.rxdata` -> `Game.rxdata.empo-path-regression.bak`
    /// (index >= 2 -> `...empo-path-regression-2.bak`).
    public static func backupName(for filename: String, index: Int = 1) -> String {
        if index <= 1 {
            return "\(filename).\(backupMarker).bak"
        }
        return "\(filename).\(backupMarker)-\(index).bak"
    }

    public static func isSaveFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".bak") {
            return isSaveFilename(String(lower.dropLast(4)))
        }
        return lower.hasSuffix(".rxdata") || lower.hasSuffix(".rvdata")
            || lower.hasSuffix(".rvdata2")
    }

    /// Merge one recovered save into its canonical location. The
    /// newer modification time wins the canonical name (ties go to
    /// `source` - the crash-then-retry case); the loser stays
    /// beside it under a `backupName`. Nothing is ever deleted.
    public static func merge(
        source: URL,
        canonical: URL,
        fm: FileManager = .default
    ) throws {
        if !fm.fileExists(atPath: canonical.path) {
            try fm.moveItem(at: source, to: canonical)
            return
        }

        let sourceIsNewer =
            modificationDate(of: source, fm: fm) >= modificationDate(of: canonical, fm: fm)
        let name = canonical.lastPathComponent
        let backup = UniqueFileName.firstAvailableURL(
            in: canonical.deletingLastPathComponent(),
            preferring: backupName(for: name),
            numbered: { backupName(for: name, index: $0) },
            fm: fm
        )

        if sourceIsNewer {
            try fm.moveItem(at: canonical, to: backup)
            try fm.moveItem(at: source, to: canonical)
        } else {
            try fm.moveItem(at: source, to: backup)
        }
    }

    private static func modificationDate(of url: URL, fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
}
