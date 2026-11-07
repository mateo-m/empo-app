/// The sheets of one screen, one at a time.
///
/// SwiftUI drops a sheet asked for while another one is up or still
/// closing. So the next sheet waits here until `closed()`, which the
/// `onDismiss` of the sheet calls.
struct SheetQueue<Sheet: Identifiable> {
    var presented: Sheet?
    private var shown: Sheet?
    private var waiting: [Sheet] = []

    mutating func show(_ sheet: Sheet) {
        waiting.append(sheet)
        showTheNext()
    }

    /// Puts a sheet before the waiting ones, for a sheet that opens
    /// the next step of the sheet that is up.
    mutating func showNext(_ sheet: Sheet) {
        waiting.insert(sheet, at: 0)
        showTheNext()
    }

    /// Returns the sheet that closed, and opens the next one.
    @discardableResult
    mutating func closed() -> Sheet? {
        let closed = shown
        shown = nil
        showTheNext()
        return closed
    }

    /// True when the sheet that is up, or one that waits, matches.
    func holds(where matches: (Sheet) -> Bool) -> Bool {
        shown.map(matches) == true || waiting.contains(where: matches)
    }

    private mutating func showTheNext() {
        guard shown == nil, !waiting.isEmpty else { return }
        shown = waiting.removeFirst()
        presented = shown
    }
}
