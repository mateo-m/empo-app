import Foundation
import UIKit

// Ticket 015 spike instrument.
//
// The spike compares two input paths by their event streams, so it
// needs an ordered record of both. `NSLog` is not enough: on a
// physical device the output stays on the phone. macOS 26 removed
// `log stream --device`, and `devicectl` has no console command.
//
// So the trace goes to a file in the app container, which
// `devicectl device copy from` can pull. The same file appears in
// the simulator container, so one reader handles both.
//
// Two threads write here. The inject side runs on the main thread.
// The SDL trace callback runs on SDL's event thread. Each line
// carries a timestamp taken by its caller BEFORE this code runs, so
// the lock never distorts the latency numbers. Sort by timestamp if
// the append order and the clock order ever disagree.
enum PointerTrace {

    private static let lock = NSLock()
    private static var handle: FileHandle?

    /// `Documents/pointer-trace.log`. The app container root, not a
    /// game container: the trace outlives any one session, and the
    /// spike compares runs across games.
    static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("pointer-trace.log")
    }

    /// Truncates the file and writes a header. Call once per run of
    /// the gesture set, so each pass starts clean.
    static func start(label: String) {
        guard let url = fileURL else { return }
        lock.lock()
        defer { lock.unlock() }

        try? handle?.close()
        handle = nil
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        writeLocked("# \(label)")
    }

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { openLocked() }
        writeLocked(line)
    }

    /// Records when UIKit handed the app a touch, on BOTH paths.
    /// This is the half of the latency pair that path A was missing:
    /// when SDL's own view handles the touch, nothing else logs
    /// `UITouch.timestamp`.
    ///
    /// `UIWindow.sendEvent` runs before any view sees the touch, so
    /// this timestamp brackets whatever the engine records next, and
    /// it costs the same on both paths. Stationary touches are
    /// dropped, because UIKit repeats them and they carry no news.
    static func observe(_ event: UIEvent, in window: UIWindow) {
        guard let touches = event.allTouches else { return }
        let seen = ProcessInfo.processInfo.systemUptime
        for touch in touches {
            let name: String
            switch touch.phase {
            case .began: name = "began"
            case .moved: name = "moved"
            case .ended: name = "ended"
            case .cancelled: name = "cancelled"
            default: continue
            }
            let point = touch.location(in: window)
            append(
                String(
                    format: "observe phase=%@ x=%d y=%d touch=%.6f seen=%.6f",
                    name, Int(point.x), Int(point.y), touch.timestamp, seen
                ))
        }
    }

    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    // MARK: - Locked helpers

    private static func openLocked() {
        guard let url = fileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    private static func writeLocked(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
