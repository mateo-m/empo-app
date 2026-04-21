import Foundation

/// Owns the logs/ directory: writes the per-launch session-history
/// file, configures per-game debug log paths, appends history entries,
/// records play time on session end, and prunes old logs.
@MainActor
final class SessionLogger {
    static let logsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)

    private static let isoFormatter = ISO8601DateFormatter()

    private let sessionHistoryPath: String
    private var sessionStartTime: Date?

    init() {
        let logsDir = Self.logsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        sessionHistoryPath = logsDir.appendingPathComponent("session-history.log").path

        let launchTime = Self.isoFormatter.string(from: Date())
        let header = Self.logHeader(title: "\(AppInfo.name) session history", extras: ["launched: \(launchTime)"])
        try? header.write(toFile: sessionHistoryPath, atomically: true, encoding: .utf8)

        pruneOldLogs(in: logsDir)
    }

    func beginSession(for game: GameEntry, debugLogsEnabled: Bool) {
        configureDebugLog(for: game, enabled: debugLogsEnabled)
        appendSessionHistory(game: game)
        sessionStartTime = Date()
    }

    /// Persists accumulated play time into the game's metadata.
    /// Safe to call when no session is active (no-op).
    func recordSessionPlayTime(for game: GameEntry?) {
        guard let game, let startTime = sessionStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        sessionStartTime = nil
        guard elapsed > 1 else { return }

        var metadata = GameMetadata.load(for: game.id)
        metadata.totalPlayTime = (metadata.totalPlayTime ?? 0) + elapsed
        metadata.lastPlayed = Date()
        metadata.save(for: game.id)
    }

    private func configureDebugLog(for game: GameEntry, enabled: Bool) {
        guard enabled else {
            mkxp_setDebugLogPath(nil)
            return
        }

        let logsDir = Self.logsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let slug = game.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let timestamp = Self.isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(game.id)-\(slug)-\(timestamp).log"
        let logPath = logsDir.appendingPathComponent(filename).path

        let header = Self.logHeader(title: "\(AppInfo.name) debug log", extras: [
            "game: \(game.title) [\(game.id)]",
            "session: \(timestamp)",
        ]) + "\n"
        try? header.write(toFile: logPath, atomically: true, encoding: .utf8)

        mkxp_setDebugLogPath(logPath)
    }

    private func appendSessionHistory(game: GameEntry) {
        let timestamp = Self.isoFormatter.string(from: Date())
        let entry = "\n[\(timestamp)] \(game.title) [\(game.id)]\n"
        if let data = entry.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: sessionHistoryPath) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        }
    }

    private func pruneOldLogs(in logsDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let logFiles = files.filter { $0.lastPathComponent != "session-history.log" && $0.pathExtension == "log" }
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
