import Foundation

/// The three shapes a member of the preferences stream carries, per
/// SPEC 5.3.
///
/// The stream that belongs to no game holds the UserDefaults export,
/// the layout profiles, and the Rescued Saves buckets. This type
/// writes the path and reads it back, so the resolver, the restore
/// destination, and the package layout share one grammar.
public enum PreferencesMemberPath: Equatable, Sendable {

    case userDefaultsExport
    /// The path under the layout profiles directory.
    case profile(path: String)
    /// The bucket name and the path inside it.
    case rescuedSavesBucket(name: String, path: String)

    public static let profilePrefix = "profiles/"
    public static let rescuedSavesPrefix = "rescued-saves/"
    public static let userDefaultsExportName = "userdefaults.json"

    public init?(_ path: String) {
        if path == Self.userDefaultsExportName {
            self = .userDefaultsExport
            return
        }
        if path.hasPrefix(Self.profilePrefix) {
            self = .profile(path: String(path.dropFirst(Self.profilePrefix.count)))
            return
        }
        guard path.hasPrefix(Self.rescuedSavesPrefix) else { return nil }
        let rest = path.dropFirst(Self.rescuedSavesPrefix.count)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self = .rescuedSavesBucket(name: String(parts[0]), path: String(parts[1]))
    }

    /// The path the member carries in the stream.
    public var path: String {
        switch self {
        case .userDefaultsExport:
            return Self.userDefaultsExportName
        case .profile(let path):
            return Self.profilePrefix + path
        case .rescuedSavesBucket(let name, let path):
            return Self.rescuedSavesPrefix + name + "/" + path
        }
    }
}
