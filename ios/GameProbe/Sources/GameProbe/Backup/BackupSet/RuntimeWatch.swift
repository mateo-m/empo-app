import Foundation

/// What Empo does with a file it saw the game write, per SPEC 3.6.
public enum RuntimeWatchOutcome: Equatable, Sendable {
    /// The file joins the backup set on its own, with the
    /// runtime-watch label. The UI shows it.
    case join
    /// The file is over the size limit, so the join stops and Empo
    /// asks once. A self-update is large and a save is not.
    case ask(sizeBytes: Int64)
    /// The file stays a suggestion. It was declined already, or the
    /// ask was answered with no.
    case suggestion
    /// Nothing to do. Full mode covers the whole tree, and a file
    /// already in the set needs no second source.
    case ignore
}

/// What one session's watch produced.
public struct RuntimeWatchResult: Equatable, Sendable {

    /// The paths that join the set now, container-relative.
    public var joined: [String]
    /// The paths over the size limit, which the UI asks about once.
    public var asks: [String]
    /// The paths that stay suggestions.
    public var suggestions: [String]

    public init(joined: [String] = [], asks: [String] = [], suggestions: [String] = []) {
        self.joined = joined
        self.asks = asks
        self.suggestions = suggestions
    }

    public var isEmpty: Bool {
        joined.isEmpty && asks.isEmpty && suggestions.isEmpty
    }
}

/// The runtime watch of SPEC 3.6, as pure rules.
///
/// The spec fixes the behavior and not the mechanism. iOS has no
/// recursive directory watch, so the app compares the size and the
/// modified time of the game tree at session start against the same
/// values at session end. `writtenPaths` is that comparison, and
/// `GameSaveWatch` in the app target takes the two readings.
///
/// A join has no store of its own. The manifest carries the label
/// per entry, per 3.6, so the joins of every earlier session come
/// back with the last manifest and the live session adds what it
/// saw.
public enum RuntimeWatch {

    /// A written file over this size stops the join and asks once,
    /// per 3.6.
    public static let askAboveBytes: Int64 = 50 * 1024 * 1024

    /// What to do with one written file.
    ///
    /// - `mode`: full mode changes nothing, per 3.6.
    /// - `declined`: the declined suggestions of `backup.json`. A
    ///   declined path never asks twice.
    /// - `alreadyInSet`: the paths the classifier, the marks, or an
    ///   earlier join already hold.
    public static func outcome(
        path: String,
        sizeBytes: Int64,
        mode: BackupMode,
        declined: Set<String>,
        alreadyInSet: Set<String>
    ) -> RuntimeWatchOutcome {
        guard mode == .slim else { return .ignore }
        if alreadyInSet.contains(path) { return .ignore }
        if declined.contains(path) { return .suggestion }
        if sizeBytes > askAboveBytes { return .ask(sizeBytes: sizeBytes) }
        return .join
    }

    /// The outcome for every written file of one session, sorted by
    /// path.
    public static func result(
        written: [BackupSetResolver.WalkedFile],
        mode: BackupMode,
        declined: Set<String>,
        alreadyInSet: Set<String>
    ) -> RuntimeWatchResult {
        var result = RuntimeWatchResult()
        for file in written.sorted(by: { $0.path < $1.path }) {
            switch outcome(
                path: file.path,
                sizeBytes: file.size,
                mode: mode,
                declined: declined,
                alreadyInSet: alreadyInSet)
            {
            case .join: result.joined.append(file.path)
            case .ask: result.asks.append(file.path)
            case .suggestion: result.suggestions.append(file.path)
            case .ignore: break
            }
        }
        return result
    }

    /// The paths the game wrote, from the two readings of one
    /// session.
    ///
    /// A path is written when it is new, or when its size or its
    /// modified time moved. A path that went away is not written,
    /// and it is not a delete either: the watch decides no delete,
    /// per invariant 3.
    ///
    /// `since` closes the race the two readings leave. The first
    /// reading walks a tree of thousands of files, and the game may
    /// write while it walks, so a save can enter the first reading
    /// already written. A modified time at or after the session
    /// start therefore counts as written whatever the two readings
    /// say. A miss here costs a save, and a false join costs one
    /// small upload.
    public static func writtenPaths(
        before: [String: FileStamp], after: [String: FileStamp], since: Date? = nil
    ) -> [String] {
        after.keys.filter { path in
            if before[path] != after[path] { return true }
            guard let since, let stamp = after[path] else { return false }
            return stamp.modifiedAt >= since
        }.sorted()
    }

    /// The declined suggestions after the user answered an ask with
    /// no, per 3.6. The list stays sorted and holds no duplicate, so
    /// the same file never asks twice.
    public static func declining(
        _ path: String, in intent: GameBackupIntent
    ) -> GameBackupIntent {
        var changed = intent
        guard !changed.declinedSuggestions.contains(path) else { return changed }
        changed.declinedSuggestions = (changed.declinedSuggestions + [path]).sorted()
        return changed
    }
}
