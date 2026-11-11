import Foundation

/// A tap launch has no console, and a Mac cannot collect the unified
/// log from a device without root, so every line also goes to a file.
/// `devicectl device copy from` pulls the file.
enum BackupLog {

    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/backup-log.txt")
    }

    /// The size at which the file starts again. A device check runs
    /// for minutes, so the file stays small.
    static let sizeLimit = 256 * 1024

    static func line(_ tag: String, _ message: String) {
        NSLog("[%@] %@", tag, message)
        write("\(stamp.string(from: Date())) [\(tag)] \(message)\n")
    }

    /// Writes one line only while the Debug logs setting is on.
    @MainActor
    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        guard AppSettings.shared.debugLogs else { return }
        line(tag, message())
    }

    private static let lock = NSLock()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let bytes = text.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? bytes.write(to: url)
            return
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > UInt64(sizeLimit) {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: bytes)
    }
}
