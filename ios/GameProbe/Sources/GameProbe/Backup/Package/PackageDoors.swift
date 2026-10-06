import Foundation

/// When export and import are open, and what they cost, per SPEC
/// 12.5 and 12.7.
public enum PackageDoors {

    /// Both doors close while a game runs, per 7.6. A package reads
    /// the same files a snapshot does, and a running game writes
    /// them.
    public static func opens(gameIsPlaying: Bool) -> Bool { !gameIsPlaying }

    public static func line(gameName: String?) -> String? {
        guard let gameName else { return nil }
        return "Close \(gameName) to export or import a backup."
    }

    /// What an export still needs, or `nil` where it fits.
    ///
    /// The check wants the whole source plus the 200 MB floor of
    /// 6.4. It is deliberately conservative: it covers the staged
    /// ZIP before compression, and Empo sets no other size limit.
    public static func shortfall(sourceBytes: Int64, freeSpaceBytes: Int64) -> Int64? {
        let needed = sourceBytes + StagingBudget.freeSpaceFloorBytes
        return freeSpaceBytes >= needed ? nil : needed - freeSpaceBytes
    }

    /// The line the export shows when it does not fit.
    public static func shortfallLine(_ shortfallText: String) -> String {
        "This export needs \(shortfallText) more free space on this device."
    }
}

/// What Empo offers after Files did not confirm a save, per SPEC
/// 12.5.
///
/// A completed ZIP stays in staging until Files confirms. Empo gets
/// no result when the app dies in the picker, so the same choice
/// returns at the next launch.
public enum PackageSaveChoice: String, Codable, Sendable, CaseIterable, Equatable {
    case saveAgain
    case delete

    public var label: String {
        switch self {
        case .saveAgain: return "Save again"
        case .delete: return "Delete"
        }
    }

    public static func question(fileName: String) -> String {
        "Empo built \(fileName) but did not save it. Save it again?"
    }

    /// Whether the choice returns for this package.
    public static func asks(isComplete: Bool, isSaved: Bool) -> Bool {
        isComplete && !isSaved
    }
}
