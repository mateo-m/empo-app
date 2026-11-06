import Foundation

/// One line of backup evidence, in the two places a device check can
/// read it.
///
/// `NSLog` writes to the unified log and to standard error.
/// `devicectl device process launch --console` prints standard error,
/// which is enough while the Mac starts the app. A tap launch has no
/// console, and a Mac cannot collect the unified log from a device
/// without root, so every line also goes to a file. The device check
/// of ticket 007 pulls the file with `devicectl device copy from`.
enum BackupLog {

    /// The file inside the app container, under
    /// `Library/Logs/backup-log.txt`.
    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/backup-log.txt")
    }

    /// The size at which the file starts again. A device check runs
    /// for minutes, so the file stays small.
    static let sizeLimit = 256 * 1024

    /// Writes one line. `tag` names the part that wrote it, without
    /// the brackets.
    static func line(_ tag: String, _ message: String) {
        NSLog("[%@] %@", tag, message)
        write("\(stamp.string(from: Date())) [\(tag)] \(message)\n")
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
