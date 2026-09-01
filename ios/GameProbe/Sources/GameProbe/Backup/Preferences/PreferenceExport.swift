import Foundation

/// What a key may do, per SPEC 10.1.
public enum PreferenceClass: String, Codable, Sendable, CaseIterable, Equatable {
    /// It travels to another device.
    case portable
    /// It stays on the device that set it.
    case deviceLocal = "device-local"
    /// It enters no backup, no package, and no sync document.
    case neverStored = "never-stored"
}

/// The allow-list of SPEC 10.1.
///
/// An allow-list is the point. A deny-list would ship the next key
/// that holds a path or a token with no review, so a key this file
/// does not name never leaves the device.
///
/// A game-scoped key is never here, per 10.2. Per-game layouts and
/// per-game controller maps live in each game's
/// `EmpoState/controls.json`, which the backup set already carries.
public enum PreferenceKeys {

    public static let portable: Set<String> = [
        "theme",
        "interfaceHaptics",
        "controllerHaptics",
        "controlsEditSnapToGrid",
        "libraryDisplayMode",
        "librarySortOption",
        "showContinuePlaying",
        "titlePosition",
        "cleanupInvalidGames",
        "controllerMap.global",
        "layoutProfiles.gameNoticeShown",
        "layoutProfiles.default",
    ]

    /// One family travels whole: every hint the user dismissed.
    public static let portablePrefix = "hint.dismissed."

    public static let deviceLocal: Set<String> = [
        "debugMode",
        "debugLogs",
        "maxLogFiles",
        "showViewportBounds",
        "showTouchZone",
        "pointerInjection",
        "vpBoundsR",
        "vpBoundsG",
        "vpBoundsB",
        "vpBoundsA",
    ]

    public static let neverStored: Set<String> = [
        "caBundleLastRefresh",
        "UpdateChecker.lastCheckedAt",
        "UpdateChecker.lastKnownLatestVersion",
        "pendingDuplicateGameNames",
        "pendingSaveRecoveries",
        // A new install must see the disclaimer once, per 10.1, so
        // restoring this key would let it skip that screen.
        "disclaimerAcknowledgedVersion",
    ]

    /// The two legacy families of 10.2. A game that the player never
    /// opened since the migration shipped may still hold one.
    public static let gameScopedPrefixes = ["controlsLayout.", "controllerMap."]

    public static func classOf(_ key: String) -> PreferenceClass? {
        if portable.contains(key) { return .portable }
        if key.hasPrefix(portablePrefix) { return .portable }
        if deviceLocal.contains(key) { return .deviceLocal }
        if neverStored.contains(key) { return .neverStored }
        return nil
    }

    /// Whether the key names one game, per 10.2.
    ///
    /// `controllerMap.global` is not game-scoped, and it is the one
    /// key of that family that travels.
    public static func isGameScoped(_ key: String) -> Bool {
        guard !portable.contains(key) else { return false }
        return gameScopedPrefixes.contains { key.hasPrefix($0) }
    }
}

/// `Preferences/defaults.json` of SPEC 12.2, and the same document
/// the preference stream of 10.3 carries.
public enum PreferenceExport {

    public static let currentVersion = 1

    /// The portable keys of `defaults`, and nothing else.
    ///
    /// A device-local key, a never-stored key, a game-scoped key,
    /// and a key no class names all stay behind.
    public static func portableValues(of defaults: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in defaults where PreferenceKeys.classOf(key) == .portable {
            out[key] = value
        }
        return out
    }

    public static func document(of defaults: [String: JSONValue], at date: Date) throws -> Data {
        let document = PreferenceDocument(
            version: currentVersion,
            exportedAt: date,
            values: portableValues(of: defaults))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(document)
    }

    public static func decode(json data: Data) throws -> PreferenceDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PreferenceDocument.self, from: data)
    }
}

public struct PreferenceDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var values: [String: JSONValue]

    public init(version: Int, exportedAt: Date, values: [String: JSONValue]) {
        self.version = version
        self.exportedAt = exportedAt
        self.values = values
    }
}
