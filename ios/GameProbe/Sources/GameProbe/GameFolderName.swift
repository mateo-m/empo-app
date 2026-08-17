import Foundation

/// Filesystem-safe directory naming for imported games.
///
/// Empo names each game's container directory after the title the
/// game declares in its INI file (`Game.ini`, or whatever `*.ini`
/// the game ships - Pokémon Uranium uses `Uranium.ini`). Titles are
/// arbitrary user-facing strings, so they are sanitized into a safe
/// single path component here.
public enum GameFolderName {

    /// Name used when a title sanitizes down to nothing.
    public static let fallback = "Unknown Game"

    /// Length cap for a sanitized name, in characters. Keeps paths
    /// readable in the Files app. Characters are grapheme clusters,
    /// which have no bounded byte size (a skin-tone emoji is 8
    /// UTF-8 bytes, a decomposed Hangul syllable 9), so
    /// `maxUTF8Bytes` enforces the filesystem limit separately.
    /// (ZWJ sequences never reach the cap: ZWJ is a format
    /// character, and the disallowed set strips those - invisible
    /// characters invite spoofed-looking folder names.)
    public static let maxLength = 60

    /// Byte cap for a sanitized name. APFS limits a path component
    /// to 255 UTF-8 bytes. Capping well below that leaves room for
    /// every suffix a caller appends (`uniqueName`'s " 999" or
    /// 37-character UUID, quarantine numbering, displaced-save
    /// markers).
    public static let maxUTF8Bytes = 180

    /// Characters replaced during sanitization. `/` and NUL are the
    /// only characters APFS forbids, but the Windows-reserved set
    /// (`\ : * ? " < > |`) is excluded too so a game folder copied
    /// out through the Files app stays portable.
    private static let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)
        .union(.newlines)
        .union(.illegalCharacters)

    /// Windows reserved device names (case-insensitive, and
    /// reserved even with an extension: `NUL.txt` is as invalid as
    /// `NUL`). A name whose first dot-segment matches gets an
    /// underscore appended to that segment for the same
    /// portability reason the character set above exists.
    private static let windowsReservedStems: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for index in 1...9 {
            names.insert("COM\(index)")
            names.insert("LPT\(index)")
        }
        for superscript in ["\u{00B9}", "\u{00B2}", "\u{00B3}"] {
            names.insert("COM\(superscript)")
            names.insert("LPT\(superscript)")
        }
        return names
    }()

    /// Sanitize a game title into a safe folder name:
    ///
    ///   - Disallowed characters become spaces.
    ///   - Whitespace runs collapse to a single space.
    ///   - Capped at `maxLength` characters AND `maxUTF8Bytes`
    ///     bytes (trimmed on grapheme boundaries).
    ///   - Leading dots go (hidden-directory prefix), and so do
    ///     trailing dots and spaces (Windows compat).
    ///   - A Windows reserved device stem (`NUL`, `COM3`,
    ///     `NUL.txt`) gets an underscore after the stem.
    ///   - An empty result falls back to `fallback`.
    ///
    /// Idempotent: `sanitize(sanitize(x)) == sanitize(x)`.
    public static func sanitize(_ title: String) -> String {
        // Invisible variants go FIRST, and they are removed rather
        // than spaced. A selector draws nothing, so the reader sees
        // no gap where it sat. See `InvisibleCharacters`.
        let visible = title.strippingInvisibleVariants()

        let replaced = visible.unicodeScalars
            .map { disallowed.contains($0) ? " " : String($0) }
            .joined()

        let collapsed =
            replaced
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Front cleanup FIRST, until stable: stripping leading dots
        // and spaces can expose a reserved stem (".NUL", ". NUL"),
        // so it must finish before the escape looks at the stem.
        var name = collapsed
        while true {
            let before = name
            name = name.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix(".") {
                name.removeFirst()
            }
            if name == before { break }
        }

        // The escape adds a character, so it runs BEFORE the caps -
        // after them it could push a boundary-length name over the
        // limit and break idempotence. Everything below trims from
        // the END only and cannot resurrect a reserved stem:
        // "NUL_.ext" trimmed to "NUL_." strips to "NUL_", still
        // escaped.
        name = escapedWindowsReservedStem(name)
        name = String(name.prefix(maxLength))
        while name.utf8.count > maxUTF8Bytes {
            name.removeLast()
        }
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }

        return name.isEmpty ? fallback : name
    }

    /// `NUL` -> `NUL_`, `NUL.txt` -> `NUL_.txt`. The underscore
    /// breaks the device-name match on Windows without hurting
    /// readability. Appending to the stem (not the whole name)
    /// matters because Windows reserves the stem regardless of
    /// extension. Idempotent: `NUL_` has stem `NUL_`, no match.
    private static func escapedWindowsReservedStem(_ name: String) -> String {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let stem = parts.first,
            windowsReservedStems.contains(stem.uppercased())
        else { return name }
        if parts.count == 2 {
            return "\(stem)_.\(parts[1])"
        }
        return "\(stem)_"
    }

    /// First free name derived from `preferred`: the name itself,
    /// then `<name> 2` ... `<name> 999`, then a UUID-suffixed
    /// fallback so the loop always terminates.
    ///
    /// `isTaken` decides collisions. Callers should compare
    /// case-insensitively so "pokemon z" and "Pokemon Z" don't end
    /// up as distinct directories that collide on a
    /// case-insensitive filesystem.
    public static func uniqueName(
        preferring preferred: String,
        isTaken: (String) -> Bool
    ) -> String {
        guard isTaken(preferred) else { return preferred }
        for index in 2...999 {
            let candidate = "\(preferred) \(index)"
            if !isTaken(candidate) { return candidate }
        }
        return "\(preferred) \(UUID().uuidString)"
    }
}
