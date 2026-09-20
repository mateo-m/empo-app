import Foundation

/// Per-game session logger. Logs live inside each game's
/// container at `<container>/Logs/`:
///
///   - `session-history.log`: chronological list of session
///     entries for THIS game, appended once per `beginSession`.
///     No header rewrite per app launch (the original cross-game
///     design needed one). Each line is a self-contained record.
///   - `<iso8601>.log`: per-session debug log when `debugLogs` is
///     on. Filename uses only the timestamp because the parent
///     dir already sits inside the game's own container
///     (`Games/<title>/Logs/`).
///
/// All path math goes through `GameContainer`. The logger is
/// stateless across games. A single instance lives on
/// `EngineSessionCoordinator` and accepts a `GameContainer` per
/// `beginSession` call.
@MainActor
final class SessionLogger {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let periodicFlushInterval: TimeInterval = 60

    private var sessionStartTime: Date?
    private var activeGame: GameEntry?
    private var periodicFlushTask: Task<Void, Never>?

    /// Runs on the main actor after the logger writes play time to disk.
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
    /// flush. It does not append another line to session-history.log.
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
            gamecore_setDebugLogPath(nil)
            return
        }

        let logsDir = container.ensureLogsDirectory()

        let start = Date()
        let logPath = logsDir.appendingPathComponent(Self.sessionLogName(for: start)).path

        let header =
            Self.logHeader(
                title: "\(AppInfo.name) debug log",
                extras: [
                    "game: \(game.title) [\(game.id)]",
                    "session: \(Self.sessionLogStampFormatter.string(from: start))",
                ]) + "\n"
        try? header.write(toFile: logPath, atomically: true, encoding: .utf8)

        gamecore_setDebugLogPath(logPath)

        let maxLogFiles = UserDefaults.standard.object(forKey: DefaultsKey.maxLogFiles) as? Int ?? 20
        Self.pruneSessionLogs(in: logsDir, keeping: maxLogFiles)
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
            // First session for this game: write a one-line header,
            // then the entry. Subsequent sessions append.
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

    /// A session log is named after the UTC time its session started,
    /// with dashes in place of colons.
    private static let sessionLogStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()

    private static let sessionLogSuffix = ".log"

    static func sessionLogName(for date: Date) -> String {
        sessionLogStampFormatter.string(from: date) + sessionLogSuffix
    }

    static func isSessionLogName(_ name: String) -> Bool {
        name.hasSuffix(sessionLogSuffix)
            && sessionLogStampFormatter.date(from: String(name.dropLast(sessionLogSuffix.count))) != nil
    }

    /// The cap counts session logs only. `Logs/` also holds files that
    /// span sessions, such as controls.json.log and engine-config.log.
    static func pruneSessionLogs(in logsDir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return }
        // The stamps have a fixed width, so name order is time order.
        for name in names.filter(isSessionLogName).sorted().dropLast(limit) {
            try? fm.removeItem(at: logsDir.appendingPathComponent(name))
        }
    }

    private static func commitSuffix() -> String {
        GitInfo.dirty ? " (dirty)" : ""
    }

    private static func logHeader(title: String, extras: [String] = []) -> String {
        var header = "\(title)\n"
        header += "commit: \(GitInfo.commit)\(commitSuffix())\n"
        header += "engine: bindings=\(GitInfo.engineFingerprint) core=\(GitInfo.engineCoreFingerprint)\n"
        for line in extras {
            header += "\(line)\n"
        }
        header += "---\n"
        return header
    }
}
