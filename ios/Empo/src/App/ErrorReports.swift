// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Sentry

@MainActor
enum ErrorReports {
    /// The end of the session log that goes with a report. The engine
    /// writes the backtrace of a script error just before the message.
    private static let logTailBytes = 256 * 1024

    private static var dsn: String {
        (Bundle.main.object(forInfoDictionaryKey: "EmpoSentryDSN") as? String) ?? ""
    }

    static func apply(enabled: Bool) {
        if enabled, !dsn.isEmpty {
            guard !SentrySDK.isEnabled else { return }
            SentrySDK.start { options in
                options.dsn = dsn
                #if DEBUG
                options.environment = "development"
                #endif
                options.attachStacktrace = false
                // Ruby and the engine install their own signal and
                // exception handlers each time a game starts, and Ruby
                // turns a SIGSEGV from a deep recursion into a
                // SystemStackError that the game can rescue (signal.c,
                // sigsegv). A second crash handler would report those
                // as crashes.
                options.enableCrashHandler = false
                // iOS records the crash in its own process, outside the
                // signal handlers, and gives it to the app at a later
                // launch, often a day later.
                options.experimental.metrickit.enabledDiagnosticReports = [.crash]
                options.enableAppHangTracking = false
                options.enableAutoSessionTracking = false
                options.enableAutoBreadcrumbTracking = false
                options.enableSwizzling = false
                // Both stay the same for each install: the SDK sets the
                // user to an install ID when no user is set.
                options.beforeSend = { @Sendable event in
                    event.user = nil
                    event.context?["app"]?["device_app_hash"] = nil
                    return event
                }
            }
        } else if SentrySDK.isEnabled {
            SentrySDK.close()
        }
    }

    /// The game's title and its session log. Nil when debug logs are off.
    typealias Game = (title: String, log: URL)

    static func gameError(_ message: String, game: Game?) {
        send(message, level: .error, fingerprint: gameErrorFingerprint(message), game: game)
    }

    private nonisolated static let exceptionLine = try? NSRegularExpression(
        pattern: #"\A[^:]+: ("# + RescuedRubyError.classNamePattern + #")\z"#)

    /// A line such as "Exception: Errno::ENOENT" or "Excepción: TypeError".
    private nonisolated static func isExceptionLine(_ line: Substring) -> Bool {
        let line = String(line)
        guard
            let match = exceptionLine?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let className = Range(match.range(at: 1), in: line)
        else { return false }
        return RescuedRubyError.isErrorClass(line[className])
    }

    /// Pokémon Essentials writes header lines such as "Game version: 1.2.1"
    /// before the "Exception: TypeError" line, the message line, and the
    /// backtrace. An error in a map event script has a second pair of
    /// lines in the message of a RuntimeError.
    nonisolated static func gameErrorFingerprint(_ message: String) -> [String] {
        // Swift reads "\r\n" as one Character, which is not "\n".
        let lines = message.split(whereSeparator: \.isNewline)
        guard var index = lines.firstIndex(where: isExceptionLine), index + 1 < lines.endIndex else {
            // The engine's line "Script 'rpg_vxace' line 960: Errno::ENOENT
            // occurred." comes before the message, so "Audio/SE/Cursor1"
            // and "Ice1" land in one issue.
            return ["error", lines.first.map(String.init) ?? ""]
        }
        // Not the last pair: `raise RuntimeError` gives the line
        // "Message: RuntimeError".
        while index + 3 < lines.endIndex, isExceptionLine(lines[index + 2]) { index += 2 }
        let frame = lines[(index + 2)...].first {
            $0.range(of: #":[0-9]+:in `"#, options: .regularExpression) != nil
        }
        // The script numbers change between versions of a game, and an
        // object's address changes on each run.
        let error = [lines[index], lines[index + 1], frame].compactMap(\.self)
            .joined(separator: "\n")
            .replacingOccurrences(of: "0x[0-9a-f]+|[0-9]+", with: "0", options: .regularExpression)
        return ["error", error]
    }

    /// Many games rescue a script error and show it with `p`, for
    /// example `p [$!.class, $!.message, $!.backtrace]` in Insurgence's
    /// `Marshal.load`. The engine shows that as a game message, not an
    /// error.
    static func gameMessage(_ message: String, game: Game?) {
        guard let error = RescuedRubyError(message) else { return }
        send(message, level: .error, fingerprint: error.fingerprint, game: game)
    }

    static func gameCrash(game: Game?) {
        send("The game crashed.", level: .fatal, fingerprint: ["crash", game?.title ?? ""], game: game)
    }

    private static func send(
        _ message: String, level: SentryLevel, fingerprint: [String], game: Game?
    ) {
        guard SentrySDK.isEnabled else { return }
        let event = Event(level: level)
        event.message = SentryMessage(formatted: message)
        event.fingerprint = fingerprint
        let log = game.flatMap { logTail(of: $0.log) }
        SentrySDK.capture(event: event) { scope in
            if let game {
                scope.setTag(value: game.title, key: "game")
            }
            if let log {
                scope.addAttachment(Attachment(data: log, filename: "session.log", contentType: "text/plain"))
            }
        }
    }

    private static func logTail(of url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0)
        return try? file.readToEnd()
    }
}

/// A Ruby error in the text that `p $!` or
/// `p [$!.class, $!.message, ...]` prints.
struct RescuedRubyError: Equatable {
    let className: String
    let message: String

    static let classNamePattern = #"(?:[A-Z]\w*::)*[A-Z]\w*"#
    private static let inspected = try? NSRegularExpression(
        pattern: #"\A#<("# + classNamePattern + #"): (.*)>\z"#, options: .dotMatchesLineSeparators)
    private static let array = try? NSRegularExpression(
        pattern: #"\A\[("# + classNamePattern + #"), "((?:[^"\\]|\\.)*)""#)

    static func isErrorClass(_ name: some StringProtocol) -> Bool {
        name.hasSuffix("Error") || name.hasSuffix("Exception") || name.hasPrefix("Errno::")
    }

    /// An object's address changes on each run, so it stays out.
    var fingerprint: [String] {
        let message = message.replacingOccurrences(
            of: "0x[0-9a-f]+", with: "0x", options: .regularExpression)
        return ["rescued", className, message]
    }

    init(className: String, message: String) {
        self.className = className
        self.message = message
    }

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = Self.inspected?.firstMatch(in: text, range: range)
                ?? Self.array?.firstMatch(in: text, range: range),
            let classRange = Range(match.range(at: 1), in: text),
            let messageRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let className = String(text[classRange])
        guard Self.isErrorClass(className) else { return nil }
        self.className = className
        message = String(text[messageRange])
    }
}
