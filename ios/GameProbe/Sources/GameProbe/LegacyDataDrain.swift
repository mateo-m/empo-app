import Foundation

/// Moves the contents of a legacy per-game `UserData/` directory
/// into the game's shared data directory. Pure directory logic in
/// GameProbe so the Linux CI tests exercise it; the app side
/// resolves the two URLs and logs the outcome.
///
/// Guarantees:
///
///   - No byte is ever deleted. Every entry either moves to its
///     canonical name, moves to a displaced marker name, or stays
///     in the source for the next attempt.
///   - Same-named directories merge recursively (a game's
///     env-derived save folder must not split into `saves/` and a
///     sibling copy the game never reads).
///   - Same-named files resolve by modification time: the NEWER
///     file wins the canonical name (ties go to the incoming file
///     - the crash-then-retry case), and the loser is archived
///     beside it as `<name>.empo-displaced[-N].bak`. The `.bak`
///     tail keeps archived copies out of the `Save*.rxdata` globs
///     game load menus run over the shared directory. A
///     byte-identical incoming file is dropped instead of
///     archived: its bytes already sit at the canonical name, and
///     archiving it would stack duplicate displaced copies on
///     every repeat merge.
///   - Type conflicts (file vs directory) keep the destination
///     entry - it is the live one the game currently reads - and
///     displace the incoming entry whole.
///   - The source directory is removed only when it drained
///     completely.
public enum LegacyDataDrain {

    /// Marker inside displaced-copy names. Public for tests and
    /// for the app-side cleanup docs.
    public static let displacedMarker = "empo-displaced"

    public struct Outcome: Equatable, Sendable {
        /// Entries moved (canonical or displaced), source-relative.
        public var movedCount: Int = 0
        /// Source-relative paths that failed to move and remain in
        /// the source directory.
        public var failures: [String] = []
        /// True when the emptied source directory itself was
        /// removed.
        public var removedSource: Bool = false
        /// True when nothing remains in the source: safe to treat
        /// the drain as finished (and, on the delete path, safe to
        /// remove the container).
        public var isComplete: Bool { failures.isEmpty }

        public init() {}
    }

    /// `Game.rxdata` -> `Game.rxdata.empo-displaced.bak`, then
    /// `...empo-displaced-2.bak` and so on.
    public static func displacedName(for filename: String, index: Int = 1) -> String {
        if index <= 1 {
            return "\(filename).\(displacedMarker).bak"
        }
        return "\(filename).\(displacedMarker)-\(index).bak"
    }

    @discardableResult
    public static func drain(
        from source: URL,
        into destination: URL,
        fm: FileManager = .default
    ) -> Outcome {
        var outcome = Outcome()
        var sourceIsDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDir),
            sourceIsDir.boolValue
        else { return outcome }

        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        drainEntries(from: source, into: destination, prefix: "", outcome: &outcome, fm: fm)

        if outcome.isComplete,
            (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true,
            (try? fm.removeItem(at: source)) != nil
        {
            outcome.removedSource = true
        }
        return outcome
    }

    private static func drainEntries(
        from source: URL,
        into destination: URL,
        prefix: String,
        outcome: inout Outcome,
        fm: FileManager
    ) {
        guard let entryNames = try? fm.contentsOfDirectory(atPath: source.path) else {
            outcome.failures.append(prefix.isEmpty ? "." : prefix)
            return
        }

        for name in entryNames.sorted() {
            let entry = source.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"

            var entryIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir)
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)

            if !targetExists {
                move(entry, to: target, relative: relative, outcome: &outcome, fm: fm)
                continue
            }
            if entryIsDir.boolValue, targetIsDir.boolValue {
                drainEntries(
                    from: entry, into: target, prefix: relative, outcome: &outcome, fm: fm)
                if (try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty == true {
                    try? fm.removeItem(at: entry)
                }
                continue
            }
            if entryIsDir.boolValue != targetIsDir.boolValue {
                // Type conflict: the destination entry is the live
                // one; the incoming entry is archived whole.
                displace(entry, near: target, relative: relative, outcome: &outcome, fm: fm)
                continue
            }

            // File vs file. A byte-identical incoming file drains
            // by dropping it - the canonical name already holds
            // those exact bytes.
            if FileContentEquality.identical(entry, target, fm: fm) {
                if (try? fm.removeItem(at: entry)) != nil {
                    outcome.movedCount += 1
                } else {
                    outcome.failures.append(relative)
                }
                continue
            }

            // Otherwise the newer modification time wins the
            // canonical name; ties go to the incoming file.
            let entryDate = modificationDate(of: entry, fm: fm)
            let targetDate = modificationDate(of: target, fm: fm)
            if entryDate >= targetDate {
                let archived = UniqueFileName.firstAvailableURL(
                    in: destination,
                    preferring: displacedName(for: name),
                    numbered: { displacedName(for: name, index: $0) },
                    fm: fm
                )
                do {
                    try fm.moveItem(at: target, to: archived)
                    try fm.moveItem(at: entry, to: target)
                    outcome.movedCount += 1
                } catch {
                    outcome.failures.append(relative)
                }
            } else {
                displace(entry, near: target, relative: relative, outcome: &outcome, fm: fm)
            }
        }
    }

    private static func move(
        _ entry: URL, to target: URL, relative: String,
        outcome: inout Outcome, fm: FileManager
    ) {
        do {
            try fm.moveItem(at: entry, to: target)
            outcome.movedCount += 1
        } catch {
            outcome.failures.append(relative)
        }
    }

    private static func displace(
        _ entry: URL, near target: URL, relative: String,
        outcome: inout Outcome, fm: FileManager
    ) {
        let name = target.lastPathComponent
        let archived = UniqueFileName.firstAvailableURL(
            in: target.deletingLastPathComponent(),
            preferring: displacedName(for: name),
            numbered: { displacedName(for: name, index: $0) },
            fm: fm
        )
        move(entry, to: archived, relative: relative, outcome: &outcome, fm: fm)
    }

    private static func modificationDate(of url: URL, fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
}
