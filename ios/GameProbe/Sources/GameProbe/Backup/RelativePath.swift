import Foundation

public enum RelativePath {

    /// A path that is not empty, does not start at `/`, and has no
    /// empty, `.`, or `..` part. A restore reads it from a storage
    /// service, so any other path could write outside the root.
    public static func staysUnderItsRoot(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
