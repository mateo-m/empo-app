import Foundation

/// What a partial snapshot does to the staleness clock, per SPEC
/// 7.2.
///
/// A snapshot that carries a partial path resets the clock only when
/// no partial path is a save member. The manifest records the
/// detection source per entry, per 3.6, so the test is mechanical
/// and `SaveMemberRule` answers it.
///
/// - A partial classifier match, watched write, or manual mark
///   leaves the clock running, because the promise is about saves.
/// - A partial log or self-update leftover in a full-mode tree
///   resets the clock, and only flags the snapshot incomplete in the
///   UI.
public enum PartialPathClock {

    /// The same save member partial on this many consecutive runs
    /// becomes the cause line in the stale warning.
    public static let runsBeforeTheCauseLine = 3

    /// The partial paths that are save members, sorted.
    public static func savePartials(in entries: [SnapshotManifest.Entry]) -> [String] {
        entries
            .filter { $0.partial && SaveMemberRule.isSaveMember($0) }
            .map(\.path)
            .sorted()
    }

    /// Whether the snapshot resets the clock.
    public static func resetsClock(entries: [SnapshotManifest.Entry]) -> Bool {
        savePartials(in: entries).isEmpty
    }

    /// Counts one run's save partials into the tally.
    ///
    /// The count is consecutive, so a path the run no longer reports
    /// partial leaves the tally rather than keeping its old count.
    public static func tally(
        _ previous: [String: Int], savePartials: [String]
    ) -> [String: Int] {
        var next: [String: Int] = [:]
        for path in savePartials {
            next[path] = (previous[path] ?? 0) + 1
        }
        return next
    }

    /// The cause the stale line names, or `nil` while no save member
    /// has reached three consecutive runs.
    public static func cause(_ tally: [String: Int]) -> StaleCause? {
        let reached = tally
            .filter { $0.value >= runsBeforeTheCauseLine }
            .keys
            .sorted()
        guard let path = reached.first else { return nil }
        return .savesPartial(path: path)
    }
}
