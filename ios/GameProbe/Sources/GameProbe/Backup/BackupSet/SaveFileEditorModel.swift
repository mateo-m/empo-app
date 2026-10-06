import Foundation

/// One row of the save-file editor of SPEC 3.7.
public struct SaveFileEntry: Equatable, Sendable {

    /// The path, relative to the game's container.
    public var path: String
    /// Which of the three sources of 3.6 found it. The row shows
    /// this label.
    public var source: DetectionSource
    public var sizeBytes: Int64

    /// Whether the picker can take the row out again.
    ///
    /// Only a mark comes out. Marks are additive and there is no
    /// exclude-mark, per 3.6, so a classifier match and a watched
    /// write stay.
    public var isRemovable: Bool { source == .manualMark }

    public init(path: String, source: DetectionSource, sizeBytes: Int64) {
        self.path = path
        self.source = source
        self.sizeBytes = sizeBytes
    }
}

/// The data behind the save-file editor of SPEC 3.7.
///
/// One view in two containers: the first-backup ask shows it as its
/// own sheet, and the Backup sheet pushes it inside its own
/// navigation stack. Ticket 017 builds the view. This is the model
/// it reads and writes.
public struct SaveFileEditorModel: Equatable, Sendable {

    /// The rows, sorted by path.
    public private(set) var entries: [SaveFileEntry]
    /// The marks as `backup.json` holds them.
    public private(set) var manualMarks: [String]

    public init(entries: [SaveFileEntry] = [], manualMarks: [String] = []) {
        self.entries = entries.sorted { $0.path < $1.path }
        self.manualMarks = manualMarks.sorted()
    }

    /// The model for one resolved backup set. Only the labelled
    /// container members are save files: the always-in files of 3.1
    /// are settings, and the editor does not offer them.
    public static func from(_ set: GameBackupSet, manualMarks: [String]) -> SaveFileEditorModel {
        let entries = set.members(under: .container).compactMap { member -> SaveFileEntry? in
            guard let source = member.detectionSource else { return nil }
            return SaveFileEntry(path: member.path, source: source, sizeBytes: member.size)
        }
        return SaveFileEditorModel(entries: entries, manualMarks: manualMarks)
    }

    /// Marks a path the picker returned. The picker is rooted at the
    /// game's `Game/`, so the path is container-relative and starts
    /// with that directory.
    ///
    /// A path a source already found becomes a mark too, so the user
    /// keeps it whatever the classifier does next.
    public mutating func add(path: String, sizeBytes: Int64 = 0) {
        guard !manualMarks.contains(path) else { return }
        manualMarks = (manualMarks + [path]).sorted()

        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].source = .manualMark
        } else {
            entries.append(
                SaveFileEntry(path: path, source: .manualMark, sizeBytes: sizeBytes))
            entries.sort { $0.path < $1.path }
        }
    }

    /// Takes a mark out. A row that no mark put there stays, and the
    /// call answers `false`.
    ///
    /// A path the classifier also finds comes back with the
    /// classifier label at the next resolve. Removing the mark takes
    /// away the user's statement, not the file.
    @discardableResult
    public mutating func remove(path: String) -> Bool {
        guard let index = manualMarks.firstIndex(of: path) else { return false }
        manualMarks.remove(at: index)
        // A mark on a directory covers its files, per 3.6, so the
        // rows the mark put there go with it.
        entries.removeAll {
            $0.source == .manualMark && BackupSetRules.mark(path, covers: $0.path)
        }
        return true
    }

    /// The intent to write back to `EmpoState/backup.json`.
    public func applied(to intent: GameBackupIntent) -> GameBackupIntent {
        var changed = intent
        changed.manualMarks = manualMarks
        return changed
    }
}
