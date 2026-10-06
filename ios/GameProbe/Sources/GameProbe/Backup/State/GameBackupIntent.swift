import Foundation

/// `EmpoState/backup.json`, per SPEC 3.8.
///
/// It holds the mode, the manual marks, and the declined suggestions.
/// This is intent and not derived data, so it never enters
/// `state.sqlite`. `EmpoState/` is always in the backup set, per 3.1,
/// so the marks ride along and come back with the game on another
/// device.
///
/// The version field is there so the mode scalar can become a
/// per-target map later, per 3.8. This reader therefore keeps every
/// field it does not understand, the mode value included, and writes
/// it back untouched. An older build must lose nothing a newer build
/// wrote.
public struct GameBackupIntent: Equatable, Sendable {

    public static let currentVersion = 1
    public static let fileName = "backup.json"

    /// The version the file carried, or `currentVersion` for a file
    /// this build made.
    public var version: Int

    /// The mode of 3.3 and 3.4. `nil` means the game has not answered
    /// the threshold ask of 3.5 yet. Ticket 003 resolves that.
    ///
    /// A future file may hold a per-target map here instead of the
    /// scalar. The getter reads no mode from a map, and a write that
    /// touches nothing gives the map back untouched. Setting the mode
    /// on such a file replaces the map with the scalar, which is a
    /// choice the caller makes.
    public var mode: BackupMode? {
        get {
            guard let label = rawMode?.string else { return nil }
            return BackupMode(rawValue: label)
        }
        set {
            rawMode = newValue.map { .string($0.rawValue) }
        }
    }

    /// Paths the user marked, relative to the game's container, per
    /// 3.6. Marks are additive only. There is no exclude-mark.
    public var manualMarks: [String]

    /// Paths the user declined when the runtime watch offered them,
    /// per 3.6. A declined path stays a suggestion and never joins
    /// the set on its own.
    public var declinedSuggestions: [String]

    /// The mode as the file carried it. A future build may write a
    /// per-target map here, and this reader gives that map back
    /// untouched.
    private var rawMode: JSONValue?

    /// Every other key the file carried.
    private var unknownFields: [String: JSONValue]

    public init(
        mode: BackupMode? = nil,
        manualMarks: [String] = [],
        declinedSuggestions: [String] = []
    ) {
        self.version = Self.currentVersion
        self.rawMode = mode.map { .string($0.rawValue) }
        self.manualMarks = manualMarks
        self.declinedSuggestions = declinedSuggestions
        self.unknownFields = [:]
    }

    // MARK: - The JSON codec

    private enum Key {
        static let version = "version"
        static let mode = "mode"
        static let manualMarks = "manualMarks"
        static let declinedSuggestions = "declinedSuggestions"

        static let known: Set<String> = [version, mode, manualMarks, declinedSuggestions]
    }

    public static func decode(json data: Data) throws -> GameBackupIntent {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        var intent = GameBackupIntent()
        intent.version = fields[Key.version]?.int ?? currentVersion
        intent.rawMode = fields[Key.mode]
        intent.manualMarks = fields[Key.manualMarks]?.stringArray ?? []
        intent.declinedSuggestions = fields[Key.declinedSuggestions]?.stringArray ?? []
        intent.unknownFields = fields.filter { !Key.known.contains($0.key) }
        return intent
    }

    public func jsonData() throws -> Data {
        var fields = unknownFields
        fields[Key.version] = .int(version)
        if let rawMode {
            fields[Key.mode] = rawMode
        }
        fields[Key.manualMarks] = .array(manualMarks.map { .string($0) })
        fields[Key.declinedSuggestions] = .array(declinedSuggestions.map { .string($0) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    // MARK: - The file

    /// Reads `EmpoState/backup.json`. A missing or unreadable file
    /// gives the empty intent, the way `GameSettings.load` does.
    public static func load(from stateDirectory: URL) -> GameBackupIntent {
        let url = stateDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
            let intent = try? decode(json: data)
        else {
            return GameBackupIntent()
        }
        return intent
    }

    /// Writes `EmpoState/backup.json`, and makes `EmpoState/` first
    /// when it is not there. An atomic write into a missing directory
    /// fails.
    public func save(to stateDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        let url = stateDirectory.appendingPathComponent(Self.fileName)
        try jsonData().write(to: url, options: .atomic)
    }
}
