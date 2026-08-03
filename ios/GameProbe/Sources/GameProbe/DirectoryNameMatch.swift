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
    /// across launches.
    public static func preferringExisting(_ name: String, among existing: [String]) -> String {
        if existing.contains(name) { return name }
        let key = name.lowercased()
        return existing.sorted().first { $0.lowercased() == key } ?? name
    }
}
