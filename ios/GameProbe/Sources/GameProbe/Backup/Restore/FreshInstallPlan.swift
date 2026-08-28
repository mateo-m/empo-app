import Foundation

/// One game on the fresh-install screen of SPEC 11.4.
///
/// Every game found across all namespaces appears once, defaulted to
/// its newest snapshot, with its source device on the row. The row
/// expands to show every snapshot found for that game, so an old
/// iPhone's history stays reachable on a new iPad.
public struct FreshInstallGameRow: Equatable, Sendable {

    /// The container folder name the newest snapshot carries.
    public var name: String
    /// Every snapshot found for this game, newest first.
    public var snapshots: [SnapshotRow]
    public var selectedSnapshotId: String
    public var isSelected: Bool

    public init(
        name: String,
        snapshots: [SnapshotRow],
        selectedSnapshotId: String,
        isSelected: Bool = true
    ) {
        self.name = name
        self.snapshots = snapshots
        self.selectedSnapshotId = selectedSnapshotId
        self.isSelected = isSelected
    }

    public var selected: SnapshotRow? {
        snapshots.first { $0.snapshotId == selectedSnapshotId }
    }

    /// The device the selected snapshot came from, which the row
    /// names.
    public var sourceDeviceName: String {
        selected?.deviceName ?? ""
    }
}

/// The two rows below the games, per 11.4.
public struct FreshInstallExtraRow: Equatable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable, Equatable {
        case preferences
        case rescuedSaves = "rescued-saves"
    }

    public var kind: Kind
    public var snapshot: SnapshotRow
    /// The buckets the row covers, for the Rescued Saves row.
    public var bucketNames: [String]
    public var isSelected: Bool

    public init(
        kind: Kind, snapshot: SnapshotRow, bucketNames: [String] = [], isSelected: Bool = true
    ) {
        self.kind = kind
        self.snapshot = snapshot
        self.bucketNames = bucketNames
        self.isSelected = isSelected
    }
}

/// The fresh-install screen, built from the merge rule of 11.2 and
/// 11.4.
///
/// Nothing restores before the confirm tap. Cancel restores nothing
/// and lands in an ordinary empty library.
public struct FreshInstallPlan: Equatable, Sendable {

    public var games: [FreshInstallGameRow]
    public var preferences: FreshInstallExtraRow?
    public var rescuedSaves: FreshInstallExtraRow?
    /// The lines that name the targets this install has not added
    /// yet.
    public var hints: [String]

    public init(
        games: [FreshInstallGameRow] = [],
        preferences: FreshInstallExtraRow? = nil,
        rescuedSaves: FreshInstallExtraRow? = nil,
        hints: [String] = []
    ) {
        self.games = games
        self.preferences = preferences
        self.rescuedSaves = rescuedSaves
        self.hints = hints
    }

    public var isEmpty: Bool {
        games.isEmpty && preferences == nil && rescuedSaves == nil
    }

    /// The rows the confirm tap restores.
    public var selectedGames: [FreshInstallGameRow] {
        games.filter(\.isSelected)
    }
}

/// The merge of SPEC 11.4, and the door of 11.3 that opens it.
public enum FreshInstallMerge {

    /// Whether the fresh-install flow opens, per 11.3.
    ///
    /// It fires once, when the user adds a first target while the
    /// library is empty. Adding a target to a library that already
    /// holds games starts nothing, and there is no restore offer
    /// before any target exists.
    public static func opens(
        libraryIsEmpty: Bool, isFirstTarget: Bool, foundNamespaces: Bool
    ) -> Bool {
        libraryIsEmpty && isFirstTarget && foundNamespaces
    }

    /// Merges the rows of every namespace into one screen.
    ///
    /// - `gameRows`: every game snapshot the scan read, from every
    ///   namespace of the target.
    /// - `preferencesRow`: the newest snapshot of the stream that
    ///   belongs to no game, or `nil` where the target holds none.
    /// - `orphanedBuckets`: the Rescued Saves buckets that stream
    ///   carries. On a fresh install nothing is installed, so every
    ///   bucket is orphaned.
    /// - `joinedSyncGroup`: the preferences row disappears when the
    ///   user joins the sync group, per 10.9.
    public static func plan(
        gameRows: [SnapshotRow],
        preferencesRow: SnapshotRow? = nil,
        orphanedBuckets: [String] = [],
        hints: [String] = [],
        joinedSyncGroup: Bool = false
    ) -> FreshInstallPlan {
        var plan = FreshInstallPlan(games: merge(gameRows), hints: hints)

        if let preferencesRow {
            if !joinedSyncGroup {
                plan.preferences = FreshInstallExtraRow(
                    kind: .preferences, snapshot: preferencesRow)
            }
            if !orphanedBuckets.isEmpty {
                plan.rescuedSaves = FreshInstallExtraRow(
                    kind: .rescuedSaves, snapshot: preferencesRow,
                    bucketNames: orphanedBuckets.sorted())
            }
        }
        return plan
    }

    /// Groups the rows by game and defaults each one to its newest
    /// snapshot.
    ///
    /// Two namespaces can name one game with names that differ by a
    /// mojibake rendering or an invisible character, so the grouping
    /// runs the ladder of 4.2 and not a string compare.
    public static func merge(_ rows: [SnapshotRow]) -> [FreshInstallGameRow] {
        var groups: [[SnapshotRow]] = []
        for row in RestorePicker.newestFirst(rows) {
            let index = groups.firstIndex { group in
                group.contains { GameIdentityMatch.matches(row.identity, $0.identity.asGame) }
            }
            if let index {
                groups[index].append(row)
            } else {
                groups.append([row])
            }
        }

        return
            groups
            .compactMap { group -> FreshInstallGameRow? in
                guard let newest = group.first else { return nil }
                return FreshInstallGameRow(
                    name: newest.identity.containerFolderName,
                    snapshots: group,
                    selectedSnapshotId: newest.snapshotId)
            }
            .sorted { $0.name < $1.name }
    }
}

extension SnapshotIdentity {

    /// The snapshot's names as a game identity, so the ladder of 4.2
    /// can match one snapshot against another.
    var asGame: GameIdentity {
        GameIdentity(
            folderName: containerFolderName, aliases: identityAlias.map { [$0] } ?? [])
    }
}
