import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// One text file about a game session: the build, the device, and the
/// session log. The log names the core and the runner, and holds the
/// output of the engine, its crash details, and what the app saw happen
/// (`SessionLogger.note`).
struct GameReport: Codable, Identifiable, Transferable {
    let gameTitle: String
    /// The session log, relative to `DataDirectory.documentsRootURL`.
    /// The folders of an app move when the app updates.
    let logPath: String

    var id: String { logPath }

    var isShareable: Bool { FileManager.default.fileExists(atPath: logURL.path) }

    private var logURL: URL {
        DataDirectory.documentsRootURL.appendingPathComponent(logPath)
    }

    /// The report of the last session that started, kept across
    /// launches so that a crash of the app does not lose it.
    static var last: GameReport? {
        get {
            UserDefaults.standard.data(forKey: DefaultsKey.lastGameReport)
                .flatMap { try? JSONDecoder().decode(GameReport.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(
                newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: DefaultsKey.lastGameReport)
        }
    }

    /// The report of the newest session log of a game, or nil when the
    /// game has none.
    @MainActor
    static func latest(gameTitle: String, in container: GameContainer) -> GameReport? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: container.logsURL.path)) ?? []
        // The stamps have a fixed width, so name order is time order.
        return names.filter(SessionLogger.isSessionLogName).max().map {
            GameReport(gameTitle: gameTitle, logURL: container.logsURL.appendingPathComponent($0))
        }
    }

    init(gameTitle: String, logURL: URL) {
        self.gameTitle = gameTitle
        let root = DataDirectory.documentsRootURL.standardizedFileURL.path + "/"
        let path = logURL.standardizedFileURL.path
        self.logPath = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { report in
            SentTransferredFile(try await report.write())
        }
    }

    /// Writes the report to a new file in the temporary folder.
    @MainActor
    func write() throws -> URL {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "The session log is missing.\n"
        let device = UIDevice.current
        let header = [
            "\(AppInfo.name) game report",
            "app: \(AppInfo.version) (\(AppInfo.build))",
            "commit: \(GitInfo.commit)\(GitInfo.dirty ? " (dirty)" : "")",
            "device: \(Self.modelIdentifier), \(device.systemName) \(device.systemVersion)",
            "game: \(gameTitle)",
            "---",
        ].joined(separator: "\n")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(
            "\(AppInfo.name) report \(logURL.deletingPathExtension().lastPathComponent).txt")
        try (header + "\n" + log).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// For example "iPhone17,1". The simulator names the Mac's CPU, so
    /// it reads the model it shows from its environment.
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }
}
