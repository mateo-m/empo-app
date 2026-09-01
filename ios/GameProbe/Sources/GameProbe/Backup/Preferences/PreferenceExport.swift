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

/// One UserDefaults key and the class SPEC 10.1 requires of it.
///
/// The initializer takes the class as its second value, so a new key
/// that names no class does not compile. 10.1 asks for that: a key
/// with no class must not ship.
public struct PreferenceEntry: Equatable, Sendable {

    public let name: String
    public let backupClass: PreferenceClass

    public init(_ name: String, _ backupClass: PreferenceClass) {
        self.name = name
        self.backupClass = backupClass
    }
}

/// The allow-list of SPEC 10.1.
///
/// An allow-list is the point. A deny-list would ship the next key
/// that holds a path or a token with no review, so a key this file
/// does not name never leaves the device. A key that is missing from
/// `all` is on the same safe side: it travels nowhere.
///
/// A game-scoped key is never here, per 10.2. Per-game layouts and
/// per-game controller maps live in each game's
/// `EmpoState/controls.json`, which the backup set already carries.
public enum PreferenceKeys {

    // MARK: - App-wide

    public static let theme = PreferenceEntry("theme", .portable)
    public static let interfaceHaptics = PreferenceEntry("interfaceHaptics", .portable)
    public static let controllerHaptics = PreferenceEntry("controllerHaptics", .portable)
    public static let controlsEditSnapToGrid = PreferenceEntry("controlsEditSnapToGrid", .portable)
    public static let debugMode = PreferenceEntry("debugMode", .deviceLocal)
    public static let debugLogs = PreferenceEntry("debugLogs", .deviceLocal)
    public static let maxLogFiles = PreferenceEntry("maxLogFiles", .deviceLocal)
    public static let showViewportBounds = PreferenceEntry("showViewportBounds", .deviceLocal)
    public static let showTouchZone = PreferenceEntry("showTouchZone", .deviceLocal)
    public static let pointerInjection = PreferenceEntry("pointerInjection", .deviceLocal)
    public static let caBundleLastRefresh = PreferenceEntry("caBundleLastRefresh", .neverStored)

    // MARK: - Library

    public static let libraryDisplayMode = PreferenceEntry("libraryDisplayMode", .portable)
    public static let librarySortOption = PreferenceEntry("librarySortOption", .portable)
    public static let showContinuePlaying = PreferenceEntry("showContinuePlaying", .portable)
    public static let titlePosition = PreferenceEntry("titlePosition", .portable)
    public static let cleanupInvalidGames = PreferenceEntry("cleanupInvalidGames", .portable)
    public static let pendingDuplicateGameNames = PreferenceEntry(
        "pendingDuplicateGameNames", .neverStored)
    public static let pendingSaveRecoveries = PreferenceEntry("pendingSaveRecoveries", .neverStored)

    // MARK: - Controls

    /// Global controller overrides. This one is not game-scoped, and
    /// it is the one key of its family that travels.
    public static let controllerMapGlobal = PreferenceEntry("controllerMap.global", .portable)
    public static let layoutProfilesGameNoticeShown = PreferenceEntry(
        "layoutProfiles.gameNoticeShown", .portable)
    /// It names a profile folder by string, so it applies only after
    /// the named profile exists on this device.
    public static let layoutProfilesDefault = PreferenceEntry("layoutProfiles.default", .portable)

    // MARK: - The viewport bounds overlay

    public static let viewportBoundsR = PreferenceEntry("vpBoundsR", .deviceLocal)
    public static let viewportBoundsG = PreferenceEntry("vpBoundsG", .deviceLocal)
    public static let viewportBoundsB = PreferenceEntry("vpBoundsB", .deviceLocal)
    public static let viewportBoundsA = PreferenceEntry("vpBoundsA", .deviceLocal)

    // MARK: - Backups

    /// The one network switch of 7.4 and the retention preset of
    /// 5.10 are device choices. 10.1 does not list them as portable,
    /// so they stay where the user set them.
    public static let backupOverCellular = PreferenceEntry("backupOverCellular", .deviceLocal)
    public static let backupRetention = PreferenceEntry("backupRetention", .deviceLocal)
    /// Both notification keys spend the one system prompt of 7.11,
    /// the same way the disclaimer key spends the one disclaimer.
    public static let backupNotificationsAsked = PreferenceEntry(
        "backupNotificationsAsked", .neverStored)
    public static let backupNotificationPromptSpent = PreferenceEntry(
        "backupNotificationPromptSpent", .neverStored)

    // MARK: - One per install

    /// A new install must see the disclaimer once, per 10.1, so
    /// restoring this key would let it skip that screen.
    public static let disclaimerAcknowledgedVersion = PreferenceEntry(
        "disclaimerAcknowledgedVersion", .neverStored)
    public static let updateCheckerLastCheckedAt = PreferenceEntry(
        "UpdateChecker.lastCheckedAt", .neverStored)
    public static let updateCheckerLastKnownLatestVersion = PreferenceEntry(
        "UpdateChecker.lastKnownLatestVersion", .neverStored)

    // MARK: - The table

    public static let all: [PreferenceEntry] = [
        theme, interfaceHaptics, controllerHaptics, controlsEditSnapToGrid, debugMode, debugLogs,
        maxLogFiles, showViewportBounds, showTouchZone, pointerInjection, caBundleLastRefresh,
        libraryDisplayMode, librarySortOption, showContinuePlaying, titlePosition,
        cleanupInvalidGames, pendingDuplicateGameNames, pendingSaveRecoveries, controllerMapGlobal,
        layoutProfilesGameNoticeShown, layoutProfilesDefault, viewportBoundsR, viewportBoundsG,
        viewportBoundsB, viewportBoundsA, backupOverCellular, backupRetention,
        backupNotificationsAsked, backupNotificationPromptSpent, disclaimerAcknowledgedVersion,
        updateCheckerLastCheckedAt, updateCheckerLastKnownLatestVersion,
    ]

    /// One family travels whole: every hint the user dismissed.
    public static let hintDismissedPrefix = "hint.dismissed."

    /// The two legacy families of 10.2. A game that the player never
    /// opened since the migration shipped may still hold one.
    public static let controlsLayoutPrefix = "controlsLayout."
    public static let controllerMapPrefix = "controllerMap."
    public static let gameScopedPrefixes = [controlsLayoutPrefix, controllerMapPrefix]

    public static func names(inClass wanted: PreferenceClass) -> Set<String> {
        Set(all.filter { $0.backupClass == wanted }.map(\.name))
    }

    public static func classOf(_ key: String) -> PreferenceClass? {
        if key.hasPrefix(hintDismissedPrefix) { return .portable }
        return all.first { $0.name == key }?.backupClass
    }

    /// Whether the key names one game, per 10.2.
    ///
    /// `controllerMap.global` is not game-scoped, and it is the one
    /// key of that family that travels.
    public static func isGameScoped(_ key: String) -> Bool {
        guard classOf(key) == nil else { return false }
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
