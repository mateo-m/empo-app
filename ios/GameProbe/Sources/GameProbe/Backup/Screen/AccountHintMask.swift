/// The account hint with the person's name hidden, or nil when the
/// hint names no person.
public enum AccountHintMask {

    public static func masked(_ hint: String, provider: BackupProviderKind) -> String? {
        if let at = hint.firstIndex(of: "@") {
            let domain = hint[hint.index(after: at)...].split(separator: ".").map(hidden)
            return hidden(hint[..<at]) + "@" + domain.joined(separator: ".")
        }
        guard provider == .webdav else { return nil }
        guard let host = hint.range(of: " at ") else { return hidden(hint[...]) }
        return hidden(hint[..<host.lowerBound]) + hint[host.lowerBound...]
    }

    /// The same number of dots for every name, so the mask hides the
    /// length too.
    private static func hidden(_ name: Substring) -> String {
        name.prefix(name.count > 3 ? 2 : 1) + "••••"
    }
}
