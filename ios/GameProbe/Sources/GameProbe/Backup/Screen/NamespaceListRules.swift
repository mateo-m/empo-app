import Foundation

/// One row of the namespace list of SPEC 13.9.
public struct BackupNamespaceRow: Equatable, Sendable {

    public var namespaceId: String
    /// The device name the namespace recorded.
    public var deviceName: String
    public var snapshotCount: Int
    public var gameCount: Int
    /// Every object under the namespace, which is what the delete
    /// frees, or `nil` where the location's listing gives no real size.
    public var totalBytes: Int64?
    public var oldestSnapshotAt: Date?
    public var newestSnapshotAt: Date?
    /// The namespace this device writes to now.
    public var isThisDevice: Bool
    /// A namespace this device left behind after a split, per 5.12.
    public var isEarlierSpace: Bool

    public init(
        namespaceId: String,
        deviceName: String,
        snapshotCount: Int,
        gameCount: Int,
        totalBytes: Int64?,
        oldestSnapshotAt: Date? = nil,
        newestSnapshotAt: Date? = nil,
        isThisDevice: Bool = false,
        isEarlierSpace: Bool = false
    ) {
        self.namespaceId = namespaceId
        self.deviceName = deviceName
        self.snapshotCount = snapshotCount
        self.gameCount = gameCount
        self.totalBytes = totalBytes
        self.oldestSnapshotAt = oldestSnapshotAt
        self.newestSnapshotAt = newestSnapshotAt
        self.isThisDevice = isThisDevice
        self.isEarlierSpace = isEarlierSpace
    }
}

/// The sheet behind the one irreversible action of SPEC 13.9.
public struct NamespaceDeleteConfirmation: Equatable, Sendable {

    public var title: String
    /// What disappears: the device, the games, the snapshots, and
    /// the date range.
    public var lines: [String]
    /// The destructive button, which names the count.
    public var buttonLabel: String
    public var spaceLine: String

    public init(title: String, lines: [String], buttonLabel: String, spaceLine: String) {
        self.title = title
        self.lines = lines
        self.buttonLabel = buttonLabel
        self.spaceLine = spaceLine
    }
}

/// The namespace list rules of SPEC 13.9.
public enum NamespaceListRules {

    public static let spaceLine =
        screenText("Empo deletes these backups from the location now. You can't undo this. Your other backups stay.")

    public static func title(of row: BackupNamespaceRow) -> String {
        row.isEarlierSpace ? screenText("This device, older backups") : row.deviceName
    }

    public static func backups(_ count: Int) -> String {
        count == 1 ? screenText("1 backup") : screenText("%lld backups", count)
    }

    /// The namespace this device writes to is marked and carries no
    /// delete. That one goes with the remove flow of 13.10.
    public static func canDelete(_ row: BackupNamespaceRow) -> Bool {
        !row.isThisDevice
    }

    /// The confirmation, or `nil` where the row carries no delete.
    ///
    /// The button names the count. Naming it is the weight this
    /// action needs, and typed confirmation is heavier than a
    /// fangame launcher earns.
    ///
    /// `dateRangeText` carries the range in the words the caller
    /// formatted, such as "4 March to 2 August 2026".
    public static func confirmation(
        for row: BackupNamespaceRow, dateRangeText: String
    ) -> NamespaceDeleteConfirmation? {
        guard canDelete(row) else { return nil }
        let snapshots = backups(row.snapshotCount)
        let games = row.gameCount == 1 ? screenText("1 game") : screenText("%lld games", row.gameCount)
        return NamespaceDeleteConfirmation(
            title: screenText("Delete the backups from %@?", title(of: row)),
            lines: [title(of: row), games, snapshots, dateRangeText],
            buttonLabel: row.snapshotCount == 1
                ? screenText("Delete 1 backup") : screenText("Delete %lld backups", row.snapshotCount),
            spaceLine: spaceLine)
    }
}
