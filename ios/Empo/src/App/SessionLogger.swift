import Foundation

/// Per-game session logger. Logs live inside each game's
/// container at `<container>/Logs/`:
///
///   - `session-history.log`: chronological list of session
///     entries for THIS game, appended once per `beginSession`.
///     No header rewrite per app launch (the original cross-game
///     design needed one); each line is a self-contained record.
///   - `<iso8601>.log`: per-session debug log when `debugLogs` is
///     on. Filename uses just the timestamp because the parent
///     dir already encodes the game's UUID + slug.
///
/// All path math goes through `GameContainer`. The logger is
/// stateless across games - a single instance lives on
/// `EngineSessionCoordinator` and accepts a `GameContainer` per
/// `beginSession` call.
@MainActor
final class SessionLogger {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let periodicFlushInterval: TimeInterval = 60

    private var sessionStartTime: Date?
    private var activeGame: GameEntry?
    private var periodicFlushTask: Task<Void, Never>?

    /// Called on the main actor after play time is written to disk.
    var onPlayTimeFlushed: ((String) -> Void)?

    init() {}

    func beginSession(
        for game: GameEntry,
        container: GameContainer,
        debugLogsEnabled: Bool
    ) {
        configureDebugLog(for: game, container: container, enabled: debugLogsEnabled)
        appendSessionHistory(game: game, container: container)
        activeGame = game
        sessionStartTime = Date()
        startPeriodicFlush()
    }

    /// Restarts the wall-clock timer after a pause or background
    /// flush without appending another line to session-history.log.
    func resumeSessionTiming(for game: GameEntry) {
        activeGame = game
        sessionStartTime = Date()
        startPeriodicFlush()
    }

    /// Persists accumulated play time into the game's metadata and
    /// ends the active timing segment. Safe to call when no session
    /// is active (no-op).
    func recordSessionPlayTime(for game: GameEntry?) {
        flushPlayTime(for: game, endSession: true)
    }

    private func startPeriodicFlush() {
        stopPeriodicFlush()
        guard activeGame != nil else { return }
        periodicFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.periodicFlushInterval))
                guard !Task.isCancelled, let self else { return }
                guard let game = self.activeGame else { return }
                self.flushPlayTime(for: game, endSession: false)
            }
        }
    }

    private func stopPeriodicFlush() {
        periodicFlushTask?.cancel()
        periodicFlushTask = nil
    }

    private func flushPlayTime(for game: GameEntry?, endSession: Bool) {
        guard let game,
            let container = game.container,
            let startTime = sessionStartTime
        else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        if endSession {
            sessionStartTime = nil
            activeGame = nil
            stopPeriodicFlush()
        } else {
            sessionStartTime = Date()
        }
        guard elapsed > 1 else { return }

        var metadata = GameMetadata.load(from: container)
        metadata.totalPlayTime = (metadata.totalPlayTime ?? 0) + elapsed
        metadata.lastPlayed = Date()
        metadata.save(to: container)
        onPlayTimeFlushed?(game.id)
    }

    private func configureDebugLog(
        for game: GameEntry,
        container: GameContainer,
        enabled: Bool
    ) {
        guard enabled else {
            mkxp_setDebugLogPath(nil)
            return
        }

        let logsDir = container.ensureLogsDirectory()

        let timestamp = Self.isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        // Filename is just the timestamp: the parent dir
        // (`<container>/Logs/`) already lives inside
        // `Games/<uuid>-<slug>/` so embedding either id or slug in
        // the filename would be redundant.
        let filename = "\(timestamp).log"
        let logPath = logsDir.appendingPathComponent(filename).path

        let header =
            Self.logHeader(
                title: "\(AppInfo.name) debug log",
                extras: [
                    "game: \(game.title) [\(game.id)]",
                    "session: \(timestamp)",
                ]) + "\n"
        try? header.write(toFile: logPath, atomically: true, encoding: .utf8)

        mkxp_setDebugLogPath(logPath)

        pruneOldLogs(in: logsDir)
    }

    private func appendSessionHistory(
        game: GameEntry,
        container: GameContainer
    ) {
        container.ensureLogsDirectory()
        let path = container.sessionHistoryURL.path
        let timestamp = Self.isoFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(game.title) [\(game.id)]\n"

        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // First session for this game: write a one-line header
            // followed by the entry. Subsequent sessions append.
            let header = "\(AppInfo.name) session history for \(game.title)\n---\n"
            try? (header + entry).write(toFile: path, atomically: true, encoding: .utf8)
            return
        }

        if let data = entry.data(using: .utf8),
            let fh = FileHandle(forWritingAtPath: path)
        {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        }
    }

    private func pruneOldLogs(in logsDir: URL) {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: logsDir, includingPropertiesForKeys: [.creationDateKey])
        else { return }

        // Only prune debug logs (<iso8601>.log); leave
        // session-history.log alone.
        let logFiles = files.filter {
            $0.lastPathComponent != "session-history.log" && $0.pathExtension == "log"
        }
        let maxLogFiles = UserDefaults.standard.object(forKey: DefaultsKey.maxLogFiles) as? Int ?? 20
        guard logFiles.count > maxLogFiles else { return }

        let sorted = logFiles.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 < d1
        }

        for file in sorted.prefix(sorted.count - maxLogFiles) {
            try? fm.removeItem(at: file)
        }
    }

    private static func commitSuffix() -> String {
        GitInfo.dirty ? " (dirty)" : ""
    }

    private static func logHeader(title: String, extras: [String] = []) -> String {
        var header = "\(title)\n"
        header += "commit: \(GitInfo.commit)\(commitSuffix())\n"
        for line in extras {
            header += "\(line)\n"
        }
        header += "---\n"
        return header
    }
}
