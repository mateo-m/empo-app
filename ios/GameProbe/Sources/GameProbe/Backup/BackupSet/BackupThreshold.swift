import Foundation

/// One enabled target and the size threshold it uses, per SPEC 3.5.
///
/// Quota is a property of the target, so a target may override the
/// app-wide default. The name is what the ask shows.
public struct BackupTargetThreshold: Equatable, Sendable {

    public var targetId: String
    public var displayName: String
    /// The override, or `nil` for the app-wide default.
    public var overrideBytes: Int64?

    public init(targetId: String, displayName: String, overrideBytes: Int64? = nil) {
        self.targetId = targetId
        self.displayName = displayName
        self.overrideBytes = overrideBytes
    }

    public var thresholdBytes: Int64 {
        overrideBytes ?? BackupThreshold.defaultBytes
    }
}

/// What the first-backup ask of SPEC 3.5 shows.
public struct BackupThresholdAsk: Equatable, Sendable {

    /// The size of the game tree, `Game/`, that the ask names.
    public var gameTreeBytes: Int64
    /// The target with the lowest threshold, which the ask names.
    public var targetId: String
    public var targetDisplayName: String
    public var thresholdBytes: Int64

    public init(
        gameTreeBytes: Int64,
        targetId: String,
        targetDisplayName: String,
        thresholdBytes: Int64
    ) {
        self.gameTreeBytes = gameTreeBytes
        self.targetId = targetId
        self.targetDisplayName = targetDisplayName
        self.thresholdBytes = thresholdBytes
    }
}

/// What the game's mode is, or what Empo must ask to learn it.
public enum BackupModeResolution: Equatable, Sendable {
    case mode(BackupMode)
    case ask(BackupThresholdAsk)
}

/// The size threshold of SPEC 3.5, and the ask it drives.
public enum BackupThreshold {

    /// The app-wide default, measured on the game tree.
    public static let defaultBytes: Int64 = 750 * 1024 * 1024

    /// The target with the lowest threshold among the enabled ones.
    /// The ask fires against this one and names it, per 3.5. A tie
    /// goes to the first target in the list.
    public static func lowest(
        among targets: [BackupTargetThreshold]
    ) -> BackupTargetThreshold? {
        targets.min { $0.thresholdBytes < $1.thresholdBytes }
    }

    /// The mode for a game, or the ask that decides it.
    ///
    /// A game that answered already keeps its answer, because 3.5
    /// asks once. A game below the lowest threshold enters full
    /// mode and never meets the ask. The answer applies to every
    /// target, because the mode is one scalar per game, per 3.8.
    ///
    /// This is also the retroactive rule of 3.10. A library
    /// imported before this feature ships has no mode in
    /// `backup.json`, so its games pass through here at the first
    /// scan and land on the same two outcomes.
    public static func resolveMode(
        intent: GameBackupIntent,
        gameTreeBytes: Int64,
        targets: [BackupTargetThreshold]
    ) -> BackupModeResolution {
        if let answered = intent.mode { return .mode(answered) }
        guard let target = lowest(among: targets) else { return .mode(.full) }
        guard gameTreeBytes >= target.thresholdBytes else { return .mode(.full) }
        return .ask(
            BackupThresholdAsk(
                gameTreeBytes: gameTreeBytes,
                targetId: target.targetId,
                targetDisplayName: target.displayName,
                thresholdBytes: target.thresholdBytes))
    }
}

/// A mode change, per SPEC 3.9.
public enum BackupModeChange {

    /// The reason a mode change writes into the dirty flag of 6.2.
    /// The app-background pass then picks the game up, because a
    /// player who chooses full mode expects the new files to upload
    /// before the nightly pass.
    public static let dirtyReason = "mode-change"

    /// The intent with the new mode.
    ///
    /// The change is reversible in both directions. A change from
    /// full mode to slim mode touches nothing on the target: it is a
    /// statement about future snapshots, and the older full-mode
    /// snapshots stay until retention drops them, per 3.9.
    public static func apply(_ mode: BackupMode, to intent: GameBackupIntent) -> GameBackupIntent {
        var changed = intent
        changed.mode = mode
        return changed
    }

    /// Whether the change needs a new run. A change to the same
    /// mode is not a change.
    public static func makesDirty(from old: BackupMode?, to new: BackupMode) -> Bool {
        old != new
    }
}
