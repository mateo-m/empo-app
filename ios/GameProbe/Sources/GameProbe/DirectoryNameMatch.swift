import Foundation

/// Case-insensitive reuse of existing directory names.
///
/// The shared data tree lives on case-sensitive APFS, but desktop
/// mkxp-z's save-sharing contract grew up on case-insensitive
/// Windows: a release whose INI title changed only in case still
/// finds its saves there. Empo honors that by reusing an existing
/// sibling that matches case-insensitively instead of creating a
/// case-variant twin next to it.
public enum DirectoryNameMatch {

    /// `name` when it exists verbatim in `existing` (or nothing
    /// matches); otherwise the first existing case-insensitive
    /// variant, picked in sorted order so the choice is stable
    /// across launches; otherwise an existing mojibake variant
    /// from the era when `decodeAsLooseText` decoded Windows-1252
    /// INI titles as Shift-JIS ("Pokémon" -> "Pok駑on"). Installs
    /// from that era hold saves under the mojibake name, and the
    /// corrected title must keep pointing at them.
    public static func preferringExisting(_ name: String, among existing: [String]) -> String {
        if existing.contains(name) { return name }
        let key = name.lowercased()
        if let caseVariant = existing.sorted().first(where: { $0.lowercased() == key }) {
            return caseVariant
        }
        if let legacy = legacyMojibakeRendering(of: name), existing.contains(legacy) {
            return legacy
        }
        return name
    }

    /// The name a Windows-1252 title got under the old decode
    /// chain: its Windows-1252 bytes read back as Shift-JIS. Nil
    /// when the round trip fails or changes nothing.
    public static func legacyMojibakeRendering(of name: String) -> String? {
        guard let bytes = name.data(using: .windowsCP1252),
            String(data: bytes, encoding: .utf8) == nil,
            let mojibake = String(data: bytes, encoding: .shiftJIS),
            mojibake != name
        else { return nil }
        return mojibake
    }
}
