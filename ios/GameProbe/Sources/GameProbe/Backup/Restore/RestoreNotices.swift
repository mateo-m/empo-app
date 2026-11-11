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
        screenText(
            "Backups from a newer version of Empo. You can restore from them. Update Empo to back up "
                + "to this location again.")

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
    public static let emptyTargetLine = screenText("No backups on this location yet")

    /// A scan that could not read the location, which is not the
    /// same as a location with nothing on it.
    public static let scanFailedLine = screenText(
        "Empo couldn't read the backups on this location. Try again.")

    public static let unreadableLine = screenText("Empo couldn't read this backup. Try another one.")

    public static let recordsUnavailableLine = screenText(
        "Empo couldn't open its records on this device. Close Empo, open it again, then try again.")

    /// What a restore ended with, per 11.14. Every line that is not a
    /// success says what to do next.
    public static func line(of outcome: RestoreOutcome) -> String {
        switch outcome {
        case .finished(let result):
            return [
                partialPathsLine(count: result.partialPathCount),
                screenText("Open the game to play from this backup."),
            ]
            .compactMap { $0 }.joined(separator: " ")
        case .notEnoughSpace(let shortfall):
            let missing = ByteCountFormatter.string(
                fromByteCount: shortfall.missingBytes, countStyle: .file)
            return screenText("This device needs %@ more free space. Free up space, then try again.", missing)
        case .stopped(let reason, _):
            switch reason {
            case .cancelled:
                return screenText("You stopped the restore. The files it already restored stay.")
            case .gameLaunched:
                return screenText(
                    "The restore stopped because a game started. Try again when you stop playing.")
            case .outOfSpace:
                return screenText("This device ran out of space. Free up space, then try again.")
            case .targetFailed:
                return screenText("Empo lost the connection to the location. Try again.")
            }
        case .failed(let message):
            return message
        }
    }

    /// The completion summary, per 11.14.
    ///
    /// A partial path restores with no question, because its bytes
    /// are real. The count is there so the user knows those files
    /// hold what they held mid-write. The line shows only when the
    /// count is above zero.
    public static func partialPathsLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return screenText(
                "1 file was being written when this backup ran. Empo restored it as it was then.")
        }
        return screenText(
            "%lld files were being written when this backup ran. Empo restored them as they were then.", count
        )
    }
}
