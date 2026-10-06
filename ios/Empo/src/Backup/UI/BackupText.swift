import Foundation
import GameProbe

/// The words the pure rules of GameProbe take as strings.
///
/// The rules stay free of a locale so their tests stay repeatable,
/// so the formatting lives here, next to the screens that show it.
enum BackupText {

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "14:03", for the unreachable line of 13.5.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "2 minutes ago", for the row of a working target.
    static func ago(_ date: Date) -> String {
        let style = Date.RelativeFormatStyle(presentation: .named)
        return date.formatted(style)
    }

    /// "today" or "on 4 March", for the status line of 13.4.
    static func day(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "today" : "on " + date.formatted(.dateTime.day().month(.wide))
    }

    /// "4 March to 2 August 2026", for the delete sheet of 13.9.
    static func range(from first: Date, to last: Date) -> String {
        let start = first.formatted(.dateTime.day().month(.wide))
        let end = last.formatted(.dateTime.day().month(.wide).year())
        return start == end ? end : "\(start) to \(end)"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
