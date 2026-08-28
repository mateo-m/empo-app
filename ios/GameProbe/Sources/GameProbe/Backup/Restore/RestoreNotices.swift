import Foundation

/// The edges of SPEC 11.14, and the summary a finished restore
/// shows.
///
/// Ticket 017 renders these. The copy is here so one place holds it.
public enum RestoreNotices {

    /// A namespace a newer Empo wrote keeps its rows enabled,
    /// because restore is read-only. The write side of the rule is
    /// in 5.16.
    public static let newerEmpoLine =
        "Backups from a newer version of Empo. You can restore from them, but this Empo cannot "
        + "back up to this target until you update."

    /// Whether the line shows for a namespace, read from a manifest
    /// the namespace holds, per 5.16.
    ///
    /// Only a newer format version says "update Empo". A namespace
    /// whose manifest does not parse is not a newer Empo, so it
    /// carries no line of its own here.
    public static func showsNewerEmpoLine(_ access: FormatAccess) -> Bool {
        guard case .readOnly(.newerFormatVersion) = access else { return false }
        return true
    }

    /// A target with nothing on it, reachable from both manual entry
    /// points.
    public static let emptyTargetLine = "No backups on this target yet"

    /// The completion summary, per 11.14.
    ///
    /// A partial path restores with no question, because its bytes
    /// are real. The count is there so the user knows those files
    /// hold what they held mid-write. The line shows only when the
    /// count is above zero.
    public static func partialPathsLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return "1 file was being written when this backup ran and was left out."
        }
        return "\(count) files were being written when this backup ran and were left out."
    }
}
