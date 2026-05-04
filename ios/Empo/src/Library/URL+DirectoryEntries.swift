import Foundation

extension URL {
    /// Lists files in this directory whose extension matches one
    /// of `extensions` (compared case-insensitively, no leading
    /// dot). Returns an empty array if the directory can't be
    /// read; callers can't usefully distinguish "empty dir" from
    /// "permission denied" anyway.
    ///
    /// Hidden files are skipped, matching the behavior we want
    /// for game folders (don't pick up `.DS_Store` etc.).
    func directoryEntries(
        matchingExtensions extensions: Set<String>,
        fm: FileManager = .default
    ) -> [URL] {
        let allowed = Set(extensions.map { $0.lowercased() })
        guard
            let entries = try? fm.contentsOfDirectory(
                at: self,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return entries.filter { allowed.contains($0.pathExtension.lowercased()) }
    }
}
