import Foundation

/// Collision-free naming for files moved into a directory that may
/// already contain the preferred name. One scheme, shared by the
/// legacy-save funnel and the UserData drain, so rescued files look
/// the same no matter which path moved them.
public enum UniqueFileName {

    /// `Game.rxdata` + 2 -> `Game-2.rxdata`; `Save` + 2 -> `Save-2`.
    /// The suffix lands before the LAST extension only:
    /// `a.b.rxdata` -> `a.b-2.rxdata`.
    public static func numbered(_ filename: String, index: Int) -> String {
        let url = URL(fileURLWithPath: filename)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
    }

    /// First name `isTaken` rejects nothing for: `preferred`, then
    /// `numbered(preferred, 2...999)`, then a UUID-prefixed
    /// fallback so the search always terminates. Pass `numbered`
    /// to override the suffix scheme (the concatenated-save
    /// recovery uses its own `.bak` marker names).
    public static func firstAvailable(
        preferring preferred: String,
        numbered: ((Int) -> String)? = nil,
        isTaken: (String) -> Bool
    ) -> String {
        guard isTaken(preferred) else { return preferred }
        for index in 2...999 {
            let candidate = numbered?(index) ?? Self.numbered(preferred, index: index)
            if !isTaken(candidate) {
                return candidate
            }
        }
        return UUID().uuidString + "-" + preferred
    }

    /// URL variant: first unused sibling of `directory/preferred`.
    public static func firstAvailableURL(
        in directory: URL,
        preferring preferred: String,
        numbered: ((Int) -> String)? = nil,
        fm: FileManager = .default
    ) -> URL {
        let name = firstAvailable(preferring: preferred, numbered: numbered) { candidate in
            fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(name)
    }
}
