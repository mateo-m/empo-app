import Foundation

/// `EmpoState/identity_aliases.json`, the alias store of SPEC 4.3.
///
/// An attach writes the old folder name here. `EmpoState/` is always
/// in the backup set, per 3.1, so the aliases ride along with the
/// game and come back with it on another device.
///
/// The manifest header carries an alias too, per 5.5, because a
/// device with no local state has no file to read. Both places hold
/// the same names.
///
/// The file carries a version field, and this reader keeps every
/// field it does not understand and writes it back untouched. An
/// older build must lose nothing a newer build wrote, the way
/// `GameBackupIntent` does it.
public struct IdentityAliases: Equatable, Sendable {

    public static let currentVersion = 1
    public static let fileName = "identity_aliases.json"

    /// The version the file carried, or `currentVersion` for a file
    /// this build made.
    public var version: Int

    /// The recorded names, oldest first. Order is the order the
    /// attaches happened in.
    public var aliases: [String]

    /// Every other key the file carried.
    private var unknownFields: [String: JSONValue]

    public init(aliases: [String] = []) {
        self.version = Self.currentVersion
        self.aliases = aliases
        self.unknownFields = [:]
    }

    // MARK: - Recording an attach

    /// Adds one alias. Answers whether the store changed.
    ///
    /// A name the game already answers to changes nothing, so a
    /// second attach of the same snapshot writes no second entry and
    /// asks no second question, per 4.3.
    @discardableResult
    public mutating func add(_ alias: String, forFolderName folderName: String) -> Bool {
        guard !GameIdentityMatch.namesMatch(alias, folderName) else { return false }
        guard !aliases.contains(where: { GameIdentityMatch.namesMatch(alias, $0) }) else {
            return false
        }
        aliases.append(alias)
        return true
    }

    /// The identity of a game whose container is `folderName`.
    public func identity(forFolderName folderName: String) -> GameIdentity {
        GameIdentity(folderName: folderName, aliases: aliases)
    }

    /// The alias a later manifest header carries, per 4.3 and 5.5.
    ///
    /// The header holds one name, so it holds the newest. An older
    /// alias stays reachable through the snapshots that carry it in
    /// their own header, because those manifests kept the old
    /// container name.
    public var manifestAlias: String? {
        aliases.last
    }

    // MARK: - The JSON codec

    private enum Key {
        static let version = "version"
        static let aliases = "aliases"

        static let known: Set<String> = [version, aliases]
    }

    public static func decode(json data: Data) throws -> IdentityAliases {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        var store = IdentityAliases()
        store.version = fields[Key.version]?.int ?? currentVersion
        store.aliases = fields[Key.aliases]?.stringArray ?? []
        store.unknownFields = fields.filter { !Key.known.contains($0.key) }
        return store
    }

    public func jsonData() throws -> Data {
        var fields = unknownFields
        fields[Key.version] = .int(version)
        fields[Key.aliases] = .array(aliases.map { .string($0) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    // MARK: - The file

    /// Reads `EmpoState/identity_aliases.json`. A missing or
    /// unreadable file gives the empty store, the way
    /// `GameBackupIntent.load` does.
    public static func load(from stateDirectory: URL) -> IdentityAliases {
        let url = stateDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
            let store = try? decode(json: data)
        else {
            return IdentityAliases()
        }
        return store
    }

    /// Writes `EmpoState/identity_aliases.json`, and makes
    /// `EmpoState/` first when it is not there. An atomic write into
    /// a missing directory fails.
    public func save(to stateDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        let url = stateDirectory.appendingPathComponent(Self.fileName)
        try jsonData().write(to: url, options: .atomic)
    }
}
