import Foundation

/// One snapshot as a row of SPEC 11.6.
///
/// A flat list, newest first, under day headers. Namespace grouping
/// stays implicit, because the device name says it.
public struct SnapshotRow: Equatable, Sendable {

    public var targetId: String
    /// The label the user gave the target, per 8.8. The rows never
    /// name a provider and never name an account.
    public var targetLabel: String
    public var namespaceId: String
    /// The device that wrote the namespace, from `device.json`.
    public var deviceName: String
    public var snapshotId: String
    public var createdAt: Date
    public var mode: BackupMode
    /// What the row says it will download.
    public var bytesToDownload: Int64
    /// The manifest carries at least one path marked `partial`, per
    /// 5.9.
    public var hasPartialPaths: Bool
    /// The version-marker flag of 11.10. It is set where the local
    /// tree's marker differs, and false where this device holds no
    /// tree.
    public var versionMarkerDiffers: Bool
    /// The marker the snapshot carries, per 4.4. The attach of 11.11
    /// names a game after the row was built, and the question of
    /// 11.10 compares against this.
    public var versionMarker: SnapshotManifest.VersionMarker
    public var identity: SnapshotIdentity
    /// The format version the manifest carried, per 5.16.
    public var formatVersion: Int

    public init(
        targetId: String,
        targetLabel: String,
        namespaceId: String,
        deviceName: String,
        snapshotId: String,
        createdAt: Date,
        mode: BackupMode,
        bytesToDownload: Int64,
        hasPartialPaths: Bool,
        versionMarkerDiffers: Bool,
        identity: SnapshotIdentity,
        formatVersion: Int = FormatDescriptor.currentVersion,
        versionMarker: SnapshotManifest.VersionMarker = SnapshotManifest.VersionMarker()
    ) {
        self.targetId = targetId
        self.targetLabel = targetLabel
        self.namespaceId = namespaceId
        self.deviceName = deviceName
        self.snapshotId = snapshotId
        self.createdAt = createdAt
        self.mode = mode
        self.bytesToDownload = bytesToDownload
        self.hasPartialPaths = hasPartialPaths
        self.versionMarkerDiffers = versionMarkerDiffers
        self.identity = identity
        self.formatVersion = formatVersion
        self.versionMarker = versionMarker
    }

    /// Builds the row from a manifest the picker read.
    ///
    /// `localVersionMarker` is `nil` on a device that holds no tree
    /// for the game, which is every row of a fresh-install restore.
    public init(
        manifest: SnapshotManifest,
        targetId: String,
        targetLabel: String,
        namespaceId: String,
        deviceName: String,
        snapshotId: String,
        localVersionMarker: SnapshotManifest.VersionMarker? = nil
    ) {
        self.init(
            targetId: targetId,
            targetLabel: targetLabel,
            namespaceId: namespaceId,
            deviceName: deviceName,
            snapshotId: snapshotId,
            createdAt: BackupKeys.timestamp(ofSnapshotId: snapshotId) ?? .distantPast,
            mode: manifest.mode,
            bytesToDownload: manifest.entries.reduce(0) { $0 + $1.size },
            hasPartialPaths: manifest.entries.contains(where: \.partial),
            versionMarkerDiffers: localVersionMarker.map { $0 != manifest.versionMarker } ?? false,
            identity: SnapshotIdentity(manifest: manifest),
            formatVersion: manifest.formatVersion,
            versionMarker: manifest.versionMarker)
    }

    /// What a reader may do with the namespace this row is in, per
    /// 5.16. A restore is read-only, so a row a newer Empo wrote
    /// stays enabled.
    public var access: FormatAccess {
        FormatDescriptor.namespaceAccess(manifestFormatVersion: formatVersion)
    }
}

/// One day header of 11.6 with the rows under it.
public struct SnapshotDaySection: Equatable, Sendable {

    public var day: Date
    public var rows: [SnapshotRow]

    public init(day: Date, rows: [SnapshotRow]) {
        self.day = day
        self.rows = rows
    }
}

/// One game's rows in the namespace list of 11.3.
public struct SnapshotGameSection: Equatable, Sendable {

    /// The installed game the rows matched, or `nil` for the
    /// trailing "Other snapshots" section of 11.11.
    public var game: GameIdentity?
    public var rows: [SnapshotRow]

    public init(game: GameIdentity?, rows: [SnapshotRow]) {
        self.game = game
        self.rows = rows
    }
}

/// Whether the manual door of 11.3 is open right now.
public enum RestoreAvailability: Equatable, Sendable {
    case available
    /// A run for this game is in flight. Restoring into a tree whose
    /// snapshot is mid-upload would ship a half-restored game.
    case runInFlight
    /// The game is playing. Its files are never scanned, never
    /// uploaded, and never restored into.
    case gameIsPlaying

    public var isAvailable: Bool { self == .available }

    public var line: String? {
        switch self {
        case .available: return nil
        case .runInFlight: return "A backup of this game is running."
        case .gameIsPlaying: return "Close the game to restore it."
        }
    }
}

/// The picker's data model, per SPEC 11.3, 11.6, and 11.11.
///
/// The three doors read the same rows. What changes between them is
/// which rows they ask for, never how a row is built.
public enum RestorePicker {

    /// The trailing section's heading, per 11.11.
    public static let otherSnapshotsHeading = "Other snapshots"

    /// Whether the manual door is open, per 11.3.
    public static func availability(
        runInFlight: Bool, gameIsPlaying: Bool
    ) -> RestoreAvailability {
        if gameIsPlaying { return .gameIsPlaying }
        if runInFlight { return .runInFlight }
        return .available
    }

    /// The manual door of 11.3: one game's snapshots across every
    /// configured target and namespace, matched through the ladder
    /// of 4.2 plus any alias.
    public static func rows(_ rows: [SnapshotRow], of game: GameIdentity) -> [SnapshotRow] {
        newestFirst(rows.filter { GameIdentityMatch.matches($0.identity, game) })
    }

    /// The namespace list of 11.3: a whole target, game by game,
    /// with the snapshots that match no installed game in a trailing
    /// section.
    public static func sections(
        _ rows: [SnapshotRow], among games: [GameIdentity]
    ) -> [SnapshotGameSection] {
        var byGame: [String: [SnapshotRow]] = [:]
        var other: [SnapshotRow] = []
        for row in rows {
            if let game = GameIdentityMatch.match(row.identity, among: games) {
                byGame[game.folderName, default: []].append(row)
            } else {
                other.append(row)
            }
        }

        var sections =
            games
            .filter { byGame[$0.folderName] != nil }
            .sorted { $0.folderName < $1.folderName }
            .map { SnapshotGameSection(game: $0, rows: newestFirst(byGame[$0.folderName] ?? [])) }
        if !other.isEmpty {
            sections.append(SnapshotGameSection(game: nil, rows: newestFirst(other)))
        }
        return sections
    }

    /// The day headers of 11.6, newest first.
    public static func days(
        _ rows: [SnapshotRow], calendar: Calendar = .current
    ) -> [SnapshotDaySection] {
        var order: [Date] = []
        var byDay: [Date: [SnapshotRow]] = [:]
        for row in newestFirst(rows) {
            let day = calendar.startOfDay(for: row.createdAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row)
        }
        return order.map { SnapshotDaySection(day: $0, rows: byDay[$0] ?? []) }
    }

    /// Newest first, with the snapshot id breaking a tie, so one set
    /// of rows always sorts the same way.
    public static func newestFirst(_ rows: [SnapshotRow]) -> [SnapshotRow] {
        rows.sorted {
            $0.createdAt == $1.createdAt
                ? $0.snapshotId > $1.snapshotId : $0.createdAt > $1.createdAt
        }
    }
}
