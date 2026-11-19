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
                // iOS and macOS record the crash outside the app's signal
                // handlers, and give it to the app at a later launch.
                options.experimental.metrickit.enabledDiagnosticReports = [.crash]
                options.enableAppHangTracking = false
                options.enableAutoSessionTracking = false
                options.enableAutoBreadcrumbTracking = false
                options.enableSwizzling = false
                options.beforeSend = beforeSend
            }
        } else if SentrySDK.isEnabled {
            SentrySDK.close()
        }
    }

    nonisolated static func beforeSend(_ event: Event) -> Event? {
        guard !isOtherAppCrash(event) else { return nil }
        // Both stay the same for each install: the SDK sets the user to
        // an install ID when no user is set.
        event.user = nil
        event.context?["app"]?["device_app_hash"] = nil
        return event
    }

    private nonisolated static let executables: Set<String> = ["Empo", "GameProcess"]

    /// LiveContainer runs other apps inside its own app, so MetricKit
    /// gives Empo their crash reports too. A crash of Empo has one of
    /// Empo's executables in its call stacks. MetricKit can leave out
    /// the name of a binary, and such a report can be Empo's. The SDK
    /// puts a binary that has no UUID in the frames but not in the images.
    private nonisolated static func isOtherAppCrash(_ event: Event) -> Bool {
        guard event.exceptions?.first?.mechanism?.type == "MXCrashDiagnostic" else { return false }
        let frames = (event.threads ?? []).flatMap { $0.stacktrace?.frames ?? [] }
        let binaries = (event.debugMeta ?? []).map(\.codeFile) + frames.map(\.package)
        return !binaries.isEmpty
            && binaries.allSatisfy { binary in binary.map { !executables.contains($0) } ?? false }
    }

    /// The game's title and its session log. Nil when debug logs are off.
    typealias Game = (title: String, log: URL)

    static func gameError(_ message: String, game: Game?, saveLoad: SaveLoad?) {
        let report = gameErrorTitle(message).map { "\($0)\n\n\(message)" } ?? message
        send(
            report, level: .error, fingerprint: gameErrorFingerprint(message), game: game, saveLoad: saveLoad)
    }

    /// The engine repaired a broken value in a save, and the game goes
    /// on. The detail is "<file name>: <fault>".
    static func saveRepaired(_ detail: String, game: Game?, saveLoad: SaveLoad?) {
        let fault = saveRepairFault(detail)
        send(
            "The engine repaired a save: \(fault)", level: .warning, fingerprint: ["save-repaired", fault],
            game: game, saveLoad: saveLoad)
    }

    /// The file name goes: a report holds file names only in the log that
    /// Debug logs adds, and the saves of all players group as one issue
    /// for each fault. A file name can hold ": ", and the fault cannot.
    nonisolated static func saveRepairFault(_ detail: String) -> String {
        detail.range(of: ": ", options: .backwards).map { String(detail[$0.upperBound...]) } ?? detail
    }

    private nonisolated static let exceptionLine = try? NSRegularExpression(
        pattern: #"\A[^:]+: ("# + RescuedRubyError.classNamePattern + #")\z"#)

    /// "Errno::ENOENT" for a line such as "Exception: Errno::ENOENT" or
    /// "Excepción: Errno::ENOENT".
    private nonisolated static func exceptionClass(of line: Substring) -> String? {
        let line = String(line)
        guard
            let match = exceptionLine?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let className = Range(match.range(at: 1), in: line),
            RescuedRubyError.isErrorClass(line[className])
        else { return nil }
        return String(line[className])
    }

    /// Pokémon Essentials writes header lines such as "Game version: 1.2.1"
    /// before the "Exception: TypeError" line, the message line, and the
    /// backtrace. An error in a map event script has a second pair of
    /// lines in the message of a RuntimeError.
    nonisolated static func gameErrorFingerprint(_ message: String) -> [String] {
        let lines = lines(of: message)
        guard let index = errorLineIndex(in: lines) else {
            // The engine's line "Script 'rpg_vxace' line 960: Errno::ENOENT
            // occurred." comes before the message, so "Audio/SE/Cursor1"
            // and "Ice1" land in one issue.
            return ["error", lines.first.map(String.init) ?? ""]
        }
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

    /// Sentry titles a message event by its first line, which is a header
    /// line such as "Game version: 1.2.1". An exception would give the
    /// title, but the SDK then attaches the stacks of Empo's threads.
    nonisolated static func gameErrorTitle(_ message: String) -> String? {
        let lines = lines(of: message)
        guard let index = errorLineIndex(in: lines), let type = exceptionClass(of: lines[index]) else {
            return nil
        }
        let line = lines[index + 1]
        let text = line.range(of: ": ").map { line[$0.upperBound...] } ?? ""
        return text.isEmpty ? type : "\(type): \(text)"
    }

    // Swift reads "\r\n" as one Character, which is not "\n".
    private nonisolated static func lines(of message: String) -> [Substring] {
        message.split(whereSeparator: \.isNewline)
    }

    /// The index of the last "Exception: TypeError" line that a message
    /// line follows.
    private nonisolated static func errorLineIndex(in lines: [Substring]) -> Int? {
        guard var index = lines.firstIndex(where: { exceptionClass(of: $0) != nil }),
            index + 1 < lines.endIndex
        else {
            return nil
        }
        // Not the last pair: `raise RuntimeError` gives the line
        // "Message: RuntimeError".
        while index + 3 < lines.endIndex, exceptionClass(of: lines[index + 2]) != nil { index += 2 }
        return index
    }

    /// Many games rescue a script error and show it with `p`, for
    /// example `p [$!.class, $!.message, $!.backtrace]` in Insurgence's
    /// `Marshal.load`. The engine shows that as a game message, not an
    /// error.
    static func gameMessage(_ message: String, game: Game?, saveLoad: SaveLoad?) {
        guard let error = RescuedRubyError(message) else { return }
        send(message, level: .error, fingerprint: error.fingerprint, game: game, saveLoad: saveLoad)
    }

    static func gameCrash(game: Game?, saveLoad: SaveLoad?) {
        send(
            "The game crashed.", level: .fatal, fingerprint: ["crash", game?.title ?? ""], game: game,
            saveLoad: saveLoad)
    }

    private static func send(
        _ message: String, level: SentryLevel, fingerprint: [String], game: Game?, saveLoad: SaveLoad?
    ) {
        guard SentrySDK.isEnabled else { return }
        let event = Event(level: level)
        event.message = SentryMessage(formatted: message)
        event.fingerprint = fingerprint
        let log = game.flatMap { logTail(of: $0.log) }
        let now = ContinuousClock.now
        SentrySDK.capture(event: event) { scope in
            if let game {
                scope.setTag(value: game.title, key: "game")
            }
            if let saveLoad {
                scope.setTag(value: saveLoad.tag(at: now), key: SaveLoad.tagKey)
                if let seconds = saveLoad.seconds(at: now) {
                    scope.setContext(value: ["seconds_since_load": seconds], key: "save_load")
                }
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

/// When the game last read a save. A report that comes soon
/// after a load can come from a damaged save. Nil in place of a
/// `SaveLoad` means that the core does not report its loads, or that
/// the report is about an earlier launch.
enum SaveLoad: Equatable {
    case never
    case at(ContinuousClock.Instant)

    static let tagKey = "save_loaded"
    static let soon = Duration.seconds(60)

    func tag(at now: ContinuousClock.Instant) -> String {
        switch self {
        case .never: "none"
        case .at(let load): now - load <= Self.soon ? "within_60s" : "over_60s"
        }
    }

    func seconds(at now: ContinuousClock.Instant) -> Int? {
        guard case .at(let load) = self else { return nil }
        return Int((now - load).components.seconds)
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
