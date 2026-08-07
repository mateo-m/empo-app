import Foundation

extension FileManager {
    /// Names of the directories directly inside `url`, unsorted.
    /// Files never appear: callers use the result for
    /// directory-name matching (`DirectoryNameMatch`, rescue-bucket
    /// scans), where a same-named FILE must not hijack a match - on
    /// case-sensitive APFS the directory can coexist with it and
    /// gets created normally. Hidden entries are included; callers
    /// that must skip them need their own listing. A missing or
    /// unreadable `url` reads as empty.
    public func subdirectoryNames(at url: URL) -> [String] {
        ((try? contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { name in
                var isDirectory: ObjCBool = false
                return fileExists(
                    atPath: url.appendingPathComponent(name).path,
                    isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }
}
