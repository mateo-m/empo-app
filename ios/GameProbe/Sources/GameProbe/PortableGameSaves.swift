import Foundation

/// Detection of "portable mode" saves: save files some games keep
/// NEXT TO their game files instead of in `System.data_directory`.
/// The deletion rescue moves these out of the doomed `Game/` tree.
/// Nothing else may touch them - a still-installed game needs them
/// exactly where they are.
///
/// Every RGSS save is a Ruby `Marshal` dump, and every Marshal
/// stream starts with the version bytes `0x04 0x08` - Essentials
/// writes saves with a bare `Marshal.dump`, no wrapper. Save STEMS
/// vary wildly across games (`Game`, `Save1`, `Uranium_1`,
/// `save_0_backup_1`, localized stems), but the extension family
/// and the Marshal magic are stable. A false positive here merely
/// preserves a file in the shared data directory. A false negative
/// deletes a player's save - so the signals form a union:
///
///   - Regular files at the game root with RGSS save extensions
///     (`.rxdata`, `.rvdata`, `.rvdata2`, `.bak` wrappers) - by
///     name, so even a truncated save or backup is preserved.
///   - Regular files at the game root with a generic save
///     extension (`.sav`, `.save`, `.savedata`) or a save-shaped
///     stem (`save`, `save1`, `savefile2`, ...), whatever the
///     extension. SPEC 3.6 of the cloud-backup design asks for
///     these before ship, and the backup set of ticket 003 reads
///     the same signals this rescue reads.
///   - Regular files at the game root whose first two bytes are
///     the Marshal magic, whatever their name.
///   - Root directories with conventional save-folder names,
///     taken whole.
///   - Any other root directory that CONTAINS a save-shaped file
///     (by extension or magic) among its immediate children,
///     taken whole - this covers renamed or localized save
///     folders without a name list.
///
/// Engine directories (`Data/`, `Graphics/`, ...) are never
/// entered: `Data/Scripts.rxdata` and friends are Marshal too,
/// but they are game assets, not saves.
public enum PortableGameSaves {

    private static let saveFolderNames: Set<String> = [
        "save", "saves", "save data", "savedata", "save game",
        "save games", "savegame", "savegames", "saved games",
        "saved_games", "save files", "savefiles", "save_data",
    ]

    /// Generic save extensions outside the RGSS family. A fangame
    /// that rolls its own save writer nearly always lands on one of
    /// these.
    private static let saveExtensions: Set<String> = [
        "sav", "save", "savedata", "savegame",
    ]

    /// Stems that name a save whatever the extension carries:
    /// `save.dat`, `savefile.bin`, `save_3` with no extension. A
    /// trailing number is a slot, so it is stripped before the
    /// match.
    private static let saveStems: Set<String> = [
        "save", "saves", "savefile", "savedata", "savegame",
        "save_data", "save_file", "save_game", "gamesave",
        "game_save",
    ]

    private static let engineFolderNames: Set<String> = [
        "data", "graphics", "audio", "fonts", "system", "movies",
    ]

    /// Names (not paths) of the portable-save entries at `gameRoot`,
    /// sorted for determinism. Empty when the root is missing.
    public static func entryNames(
        atGameRoot gameRoot: URL,
        fm: FileManager = .default
    ) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(atPath: gameRoot.path) else {
            return []
        }
        return entries.filter { name in
            let url = gameRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            if isDirectory.boolValue {
                let lowered = name.lowercased()
                if engineFolderNames.contains(lowered) { return false }
                if saveFolderNames.contains(lowered) { return true }
                return containsSaveShapedFile(url, fm: fm)
            }
            return isSaveShapedFile(name: name, at: url, fm: fm)
        }.sorted()
    }

    /// First two bytes are Ruby Marshal's version magic `0x04 0x08`.
    static func hasMarshalMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 2), bytes.count == 2 else {
            return false
        }
        return bytes[bytes.startIndex] == 0x04 && bytes[bytes.startIndex + 1] == 0x08
    }

    private static func isSaveShapedFile(name: String, at url: URL, fm: FileManager) -> Bool {
        if ConcatenatedSaveRecovery.isSaveFilename(name) { return true }
        if hasGenericSaveName(name) { return true }
        return hasMarshalMagic(url)
    }

    /// The generic save signals of SPEC 3.6: a save extension, or a
    /// save-shaped stem with any extension. A trailing `.bak` is
    /// stripped first, the way the RGSS check strips it.
    static func hasGenericSaveName(_ name: String) -> Bool {
        var lower = name.lowercased()
        while lower.hasSuffix(".bak") {
            lower = String(lower.dropLast(4))
        }
        guard !lower.isEmpty, !lower.hasPrefix(".") else { return false }

        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, let last = parts.last, saveExtensions.contains(String(last)) {
            return true
        }
        let stem = parts.count > 1 ? parts.dropLast().joined(separator: ".") : lower
        return saveStems.contains(slotNumberRemoved(from: stem))
    }

    /// `save_3` -> `save`, `save1` -> `save`. The separator before
    /// the number is optional, and a stem that is only digits stays
    /// as it is.
    private static func slotNumberRemoved(from stem: String) -> String {
        var trimmed = Substring(stem)
        while let last = trimmed.last, last.isNumber {
            trimmed = trimmed.dropLast()
        }
        if let last = trimmed.last, last == "_" || last == "-" || last == " " {
            trimmed = trimmed.dropLast()
        }
        return trimmed.isEmpty ? stem : String(trimmed)
    }

    private static func containsSaveShapedFile(_ directory: URL, fm: FileManager) -> Bool {
        guard let children = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return children.contains { child in
            let url = directory.appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { return false }
            return isSaveShapedFile(name: child, at: url, fm: fm)
        }
    }
}
