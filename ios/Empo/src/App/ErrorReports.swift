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
        let firstLine = String(message.prefix { $0 != "\n" })
        // Group by the first line, so that "File Data/Map150.rxdata not
        // found" and "Map151" land in one issue.
        send(message, level: .error, fingerprint: ["error", firstLine], game: game)
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

    private static let className = #"((?:[A-Z]\w*::)*[A-Z]\w*)"#
    private static let inspected = try! NSRegularExpression(
        pattern: #"\A#<"# + className + #": (.*)>\z"#, options: .dotMatchesLineSeparators)
    private static let array = try! NSRegularExpression(
        pattern: #"\A\["# + className + #", "((?:[^"\\]|\\.)*)""#)

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
            let match = Self.inspected.firstMatch(in: text, range: range)
                ?? Self.array.firstMatch(in: text, range: range),
            let classRange = Range(match.range(at: 1), in: text),
            let messageRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let className = String(text[classRange])
        guard
            className.hasSuffix("Error") || className.hasSuffix("Exception")
                || className.hasPrefix("Errno::")
        else { return nil }
        self.className = className
        message = String(text[messageRange])
    }
}
