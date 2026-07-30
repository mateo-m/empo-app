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

    /// Length cap for a sanitized name, in characters. Chosen so
    /// even a title of 4-byte scalars (60 x 4 = 240 UTF-8 bytes)
    /// stays under the 255-byte filesystem component limit with
    /// room for the `uniqueName` collision suffix, while keeping
    /// paths readable in the Files app.
    public static let maxLength = 60

    /// Characters replaced during sanitization. `/` and NUL are the
    /// only characters APFS forbids, but the Windows-reserved set
    /// (`\ : * ? " < > |`) is excluded too so a game folder copied
    /// out through the Files app stays portable.
    private static let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)
        .union(.newlines)
        .union(.illegalCharacters)

    /// Sanitize a game title into a safe folder name:
    ///
    ///   - Disallowed characters become spaces.
    ///   - Whitespace runs collapse to a single space.
    ///   - Capped at `maxLength` characters.
    ///   - Leading dots go (hidden-directory prefix), and so do
    ///     trailing dots and spaces (Windows compat).
    ///   - An empty result falls back to `fallback`.
    ///
    /// Idempotent: `sanitize(sanitize(x)) == sanitize(x)`.
    public static func sanitize(_ title: String) -> String {
        let replaced = title.unicodeScalars
            .map { disallowed.contains($0) ? " " : String($0) }
            .joined()

        let collapsed =
            replaced
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var name = String(collapsed.prefix(maxLength))
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespaces)

        return name.isEmpty ? fallback : name
    }

    /// First free name derived from `preferred`: the name itself,
    /// then `<name> 2` ... `<name> 999`, then a UUID-suffixed
    /// fallback so the loop always terminates.
    ///
    /// `isTaken` decides collisions; callers should compare
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
