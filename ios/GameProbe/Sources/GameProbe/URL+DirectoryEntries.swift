import Foundation

extension URL {
    /// Lists files in this directory whose extension matches one
    /// of `extensions` (case-insensitive, no leading dot). Returns
    /// an empty array if the directory cannot be read. Callers
    /// cannot usefully tell "empty dir" from "permission denied"
    /// anyway.
    ///
    /// The list skips hidden files. That is the behavior we want
    /// for game folders (do not pick up `.DS_Store` and similar).
    public func directoryEntries(
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
