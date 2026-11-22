// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Decodes RPG Maker `Scripts.{rxdata,rvdata,rvdata2}` files and
/// classifies the Ruby source inside as modern (3.x grammar) or
/// legacy (1.8/1.9 grammar). Each script entry holds zlib-deflated
/// source in a Ruby Marshal envelope.
///
/// `GameScriptProfile` uses this to tell vanilla RPG Maker
/// games apart from forks. In vanilla games, the file extension
/// pins the Ruby version. Forks such as Pokemon Reborn 19.5+ and
/// Pokemon Essentials v20+ keep the original RGSS data layout but
/// port their scripts to modern Ruby grammar.
///
/// The Marshal mini-decoder reads only the narrow subset that RPG
/// Maker emits: an outer Array of 3-tuples [Integer, String,
/// String], where the third String is zlib-deflated Ruby source.
/// On anything outside that subset, the decoder stops and returns
/// `.inconclusive`. The caller treats `.inconclusive` as "fall
/// back to the extension or the default", so a decoder bug is not
/// fatal.
public enum RubyScriptGrammarSniffer {

    public enum Result: Equatable, Sendable {
        /// The source contains modern Ruby grammar tokens (`&.`,
        /// kwargs, pattern matching, endless def). Ruby 1.8/1.9
        /// cannot parse these tokens, so this is a sure signal
        /// for 3.x dispatch.
        case modern

        /// The sniffer read the script source but found no modern
        /// tokens. The caller should use the data file extension
        /// to choose between 1.8 (`.rxdata`, `.rvdata`) and 1.9
        /// (`.rvdata2`).
        case legacy

        /// Legacy grammar that also calls Ruby 1.9+ methods, such as
        /// `force_encoding`, or has a 1.9 block parameter default.
        /// Ruby 1.8 lacks the methods and the grammar, and plain
        /// Ruby 3.1 rejects the grammar, so only Ruby 3.1 with the
        /// legacy syntax transform runs it (Vinemon Sauce Edition).
        case mixed

        /// The sniffer could not read the live source. Causes: an
        /// archive that it cannot read, a missing file, a parse
        /// error, an unknown Marshal tag, or scripts packed in a
        /// `Data/*.fpk` archive. The caller falls back to
        /// packaging signals, the extension, Game.ini, or the
        /// default.
        case inconclusive
    }

    enum CoreScripts: Equatable, Sendable {
        case read
        /// The sniffer read them from the encrypted archive, so the
        /// extension of a loose Scripts file says nothing about them.
        case archived
        /// A `Data/*.fpk` archive holds them, so the sniffer skipped them.
        case packed
        case unread
    }

    /// Sniffs a game directory. The sniffer reads loose `.rb`
    /// files first. The mkxp-z runtime loads those on top of the
    /// compiled Scripts.rxdata, so they are the live source for
    /// forks that ship both. The sniffer then falls back to the
    /// compiled `Scripts.{rxdata,rvdata,rvdata2}` file, unless a
    /// packed script archive makes that file a stale bootstrap.
    /// It runs the grammar classifier on those scripts.
    static func sniff(gameDirectory: URL) -> (result: Result, core: CoreScripts) {
        let fm = FileManager.default

        // Loose .rb files take priority. Forks like Pokemon Reborn
        // 19.5+ ship only loose scripts and no compiled file.
        // Forks like Pokemon Infinite Fusion ship loose scripts
        // next to a stale compiled Scripts.rxdata. The loose files
        // are the live runtime. The .rxdata is a leftover.
        let looseURLs = locateLooseScripts(in: gameDirectory, fm: fm)
        let extras =
            (decodePluginScripts(in: gameDirectory) ?? [])
            + readLooseScripts(urls: locateConfigScripts(in: gameDirectory, besides: looseURLs, fm: fm))
        if !looseURLs.isEmpty {
            let scripts = readLooseScripts(urls: looseURLs)
            if !scripts.isEmpty {
                return (classify(scripts: scripts + extras), .read)
            }
        }

        // Packed scripts. Post-2020 custom engines keep the real
        // scripts in a 7z `Data/*.fpk` archive and mount it at
        // run time (Pokemon Flux: `Data/Data_0.fpk`). The compiled
        // Scripts file next to it is a small bootstrap, not the
        // live source, so the sniffer must not classify it.
        if hasPackedScriptArchive(in: gameDirectory, fm: fm) {
            return (classifyExtrasAlone(extras), .packed)
        }

        // Compiled Scripts file. Vanilla RPG Maker XP / VX /
        // VX Ace projects use it, and so do forks that did not
        // extract their scripts. The engine reads the copy in the
        // encrypted archive before the one in the game folder.
        if let scripts = archivedScripts(in: gameDirectory, fm: fm) {
            return (classify(scripts: scripts + extras), .archived)
        }
        guard
            let scripts = locateCompiledScriptsFile(in: gameDirectory, fm: fm)
                .flatMap({ try? Data(contentsOf: $0) }).flatMap(decodeScripts)
        else {
            return (classifyExtrasAlone(extras), .unread)
        }
        return (classify(scripts: scripts + extras), .read)
    }

    /// Without the core scripts, legacy-looking plugin or config script
    /// code says nothing about the core. Modern or mixed code still
    /// rules out the older Rubies, because the engine runs it too.
    private static func classifyExtrasAlone(_ extras: [String]) -> Result {
        let result = extras.isEmpty ? .inconclusive : classify(scripts: extras)
        return result == .legacy ? .inconclusive : result
    }

    // MARK: - File location

    private static let scriptsFilenames = [
        "Scripts.rxdata",
        "Scripts.rvdata",
        "Scripts.rvdata2",
    ]

    static let looseScriptDirs = [
        "Scripts",
        "Data/Scripts",
    ]

    /// True when `Data/` holds a packed script archive. Vanilla
    /// RPG Maker never uses `.fpk`.
    private static func hasPackedScriptArchive(in gameDirectory: URL, fm: FileManager) -> Bool {
        let dataDir = gameDirectory.appendingPathComponent("Data")
        return !dataDir.directoryEntries(matchingExtensions: ["fpk"], fm: fm).isEmpty
    }

    private static func locateCompiledScriptsFile(
        in gameDirectory: URL,
        fm: FileManager
    ) -> URL? {
        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Data"),
        ]
        for dir in candidates {
            for name in scriptsFilenames {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private static func archivedScripts(in gameDirectory: URL, fm: FileManager) -> [String]? {
        let names =
            RGSSArchive.gameINI(in: gameDirectory, fm: fm).map {
                [$0.scripts.replacingOccurrences(of: "\\", with: "/")]
            }
            ?? scriptsFilenames.flatMap { [$0, "Data/\($0)"] }
        let paths = Set(names.map { $0.lowercased() })
        return RGSSArchive.mountable(in: gameDirectory, fm: fm)
            .flatMap { RGSSArchive.file(at: paths, in: $0) }.flatMap(decodeScripts)
    }

    /// Walks `Scripts/` and `Data/Scripts/` to find `.rb` files.
    /// The walk stops at `maxLooseFiles` so a project with
    /// thousands of scripts cannot make the sniff slow.
    private static let maxLooseFiles = 200

    static func locateLooseScripts(
        in gameDirectory: URL,
        fm: FileManager
    ) -> [URL] {
        var found: [URL] = []
        for relPath in looseScriptDirs {
            let dir = gameDirectory.appendingPathComponent(relPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                isDir.boolValue
            else {
                continue
            }
            // The recursive enumerator finds the nested
            // per-feature folders that some forks use (for
            // example, a Plugins layout).
            guard
                let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "rb" {
                found.append(url)
                if found.count >= maxLooseFiles { return found }
            }
        }
        return found
    }

    /// The files that the game's `mkxp.json` names in `preloadScript`
    /// and `postloadScript`, as one string or an array. The engine
    /// runs them before and after the Scripts file, from any folder.
    static func locateConfigScripts(in gameDirectory: URL, besides looseURLs: [URL], fm: FileManager) -> [URL]
    {
        guard let config = ManagedMkxpConfig.loadBaseDict(from: gameDirectory) else { return [] }
        var seenPaths = Set(looseURLs.map { $0.resolvingSymlinksInPath().path })
        return ["preloadScript", "postloadScript"]
            .flatMap { key -> [String] in
                switch config[key] {
                case let name as String: [name]
                case let names as [Any]: names.compactMap { $0 as? String }
                default: []
                }
            }
            .map { gameDirectory.appendingPathComponent($0) }
            .filter {
                fm.fileExists(atPath: $0.path) && seenPaths.insert($0.resolvingSymlinksInPath().path).inserted
            }
    }

    /// Reads up to `maxLooseFiles` `.rb` files, and stops after 16 MB.
    /// Pokemon Rejuvenation ships about 15 MB of loose scripts, half of
    /// them data tables, and the read order is the disk order.
    private static func readLooseScripts(urls: [URL]) -> [String] {
        var scripts: [String] = []
        var total = 0
        let cap = 16_000_000
        for url in urls {
            guard let str = try? Data(contentsOf: url).decodeAsLooseText() else { continue }
            scripts.append(str)
            total += str.utf8.count
            if total > cap { break }
        }
        return scripts
    }

    // MARK: - Marshal + Zlib decode

    private static func decodeScripts(_ data: Data) -> [String]? {
        var reader = MarshalReader(data: data)
        guard reader.readVersion() else { return nil }
        // The outer container is an array of script entries.
        guard reader.expect(0x5b) else { return nil }  // '['
        guard let count = reader.readLong(), count >= 0, count < 100_000 else {
            return nil
        }

        var scripts: [String] = []
        var total = 0
        // Cap the total inflated source. A corrupted file with a
        // huge claimed count then cannot run us out of memory.
        // 4 MB is about 10x the largest real Scripts file we have
        // seen.
        let combinedCap = 4_000_000

        for _ in 0..<count {
            guard reader.expect(0x5b) else { return nil }  // inner '['
            guard let innerCount = reader.readLong(), innerCount == 3 else {
                return nil
            }
            // Element 0: script id (Integer). Skip.
            guard reader.skipValue() else { return nil }
            // Element 1: title (String). Skip.
            guard reader.skipValue() else { return nil }
            // Element 2: deflated source (String of binary bytes).
            guard let deflated = reader.readStringBytes() else { return nil }

            if let inflated = inflate(deflated),
                let source = inflated.decodeAsLooseText()
            {
                scripts.append(source)
                total += source.utf8.count
                if total > combinedCap { break }
            }
        }
        return scripts.isEmpty ? nil : scripts
    }

    /// Pokemon Essentials v19+ keeps the plugin code out of the Scripts
    /// file. The file is an Array of [name, metadata Hash, [[path,
    /// deflated source], ...]]. In Pokemon Tectonic, the Scripts file
    /// holds only the Essentials core, and all the Ruby 3 code is here.
    private static func decodePluginScripts(in gameDirectory: URL) -> [String]? {
        let url = gameDirectory.appendingPathComponent("Data/PluginScripts.rxdata")
        guard let data = try? Data(contentsOf: url) else { return nil }
        var reader = MarshalReader(data: data)
        guard reader.readVersion(), reader.expect(0x5b),
            let count = reader.readLong(), count >= 0, count < 100_000
        else { return nil }
        var scripts: [String] = []
        var total = 0
        let combinedCap = 4_000_000
        for _ in 0..<count {
            guard reader.expect(0x5b), reader.readLong() == 3,
                reader.skipValue(), reader.skipValue(),
                reader.expect(0x5b), let files = reader.readLong(), files >= 0
            else { return nil }
            for _ in 0..<files {
                guard reader.expect(0x5b), reader.readLong() == 2, reader.skipValue(),
                    let deflated = reader.readStringBytes()
                else { return nil }
                if let source = inflate(deflated)?.decodeAsLooseText() {
                    scripts.append(source)
                    total += source.utf8.count
                    if total > combinedCap { return scripts }
                }
            }
        }
        return scripts
    }

    private static func inflate(_ data: Data) -> Data? {
        ZlibInflate.inflateSkippingZlibHeader(data)
    }

    // MARK: - Grammar classifier

    /// Patterns that imply Ruby >= 3.0 grammar (or at minimum
    /// >= 2.x for some). Each entry is an NSRegularExpression
    /// pattern. The classifier matches them across the joined
    /// script source.
    ///
    /// The set is conservative. Every entry must be a token that
    /// a 1.8/1.9 parser cannot parse at all, not only one that
    /// looks modern in style. A false positive here tags a
    /// vanilla 1.8 game as modern, and then the game will not
    /// boot.
    private static let modernTokens: [String] = [
        // Safe call (2.3+): foo&.bar
        #"&\."#,
        // Pattern matching (3.0+): `case x` with an `in pat`
        // branch. The `in` branch must appear directly after the
        // case expression, with only whitespace, comments, or
        // semicolons between. Without this rule, normal RGSS
        // `case ... when ... end` blocks in legacy scripts match
        // all the time.
        #"\bcase\b(?:\s|#.*?$|;)+[^\n;#]+(?:\s|#.*?$|;)+\bin\b\s*[\[\{\(\w]"#,
        // Endless method def (3.0+): `def foo = expr`. The
        // pattern excludes setter methods (`def x=(v)`). Setters
        // are common in RGSS1 and were mistaken for endless defs
        // before. RGSS2/3 also name the defense stat `def`
        // (`actor.def`, `Vocab::def`, `def def`). The lookbehind
        // skips the call form, and the name must follow on the
        // same line, or `Vocab::def` plus an assignment on the
        // next line reads as an endless def.
        #"(?<![.:\w])def[ \t]+(?!\w+=)\w+(?:\([^)]*\))?[ \t]*=[ \t]*(?!\()\S"#,
        // Numbered block params (2.7+): _1, _2 inside { ... }
        #"\{\s*[^}]*\b_[1-9]\b"#,
        // Keyword-arg shorthand (3.1+): foo(x:, y:)
        #"\b\w+:\s*[,)]"#,
        // Keyword parameter (2.0+): `def f(a, b = [1], c: 1)`. A label
        // inside a bracket of a default value (`g(k: 1)`, `[k: 1]`) is a
        // 1.9 hash.
        #"(?<![.:\w])def[ \t]+[\w.?!]+[ \t]*\((?:(?:[^{(\[)\n]|\{[^{}()\[\]\n]*\}|\([^{}()\[\]\n]*\)|\[[^{}()\[\]\n]*\])*,)?[ \t]*\w+:(?!:)"#,
        // Hash#except (3.0+): h.except(:k)
        #"\.except\s*\("#,
        // Array#filter_map (2.7+): arr.filter_map { ... }
        #"\.filter_map\b"#,
        // Object#then or yield_self (2.5+/2.6+): obj.then { ... }
        #"\.then\s*\{\s*\|"#,
    ]

    /// A magic comment (2.3+, common in modern code). It counts only
    /// on a line that holds nothing else, in the comment lines at the
    /// top of a script, where Ruby reads it.
    private static let frozenStringLiteral = try? NSRegularExpression(
        pattern: #"^\s*#\s*frozen_string_literal:\s*true\s*$"#)

    /// Threshold to declare the source modern. A single match can
    /// come from an embedded test fixture or chance.
    /// Three or more tokens across the whole source is a strong
    /// signal.
    private static let modernThreshold = 3

    private static func classify(scripts: [String]) -> Result {
        // Swift reads "\r\n" as one Character, so a split on "\n" alone
        // keeps a Windows file as one line.
        let scripts = scripts.map { $0.replacingOccurrences(of: "\r\n", with: "\n") }
        // Each script ends its own heredocs.
        let code = scripts.map(codeOnly).joined(separator: "\n")
        var hits = scripts.filter(startsFrozen).count
        let range = NSRange(code.startIndex..., in: code)
        for pattern in modernTokens {
            if hits >= modernThreshold { return .modern }
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.anchorsMatchLines]
                )
            else { continue }
            hits += regex.numberOfMatches(in: code, range: range)
        }
        if hits >= modernThreshold { return .modern }
        if blockParameterDefault?.firstMatch(in: code, range: range) != nil { return .mixed }
        return scripts.contains(where: callsRuby19Methods) ? .mixed : .legacy
    }

    /// A block parameter with a default value (1.9+), as in
    /// `do |hwnd = 0|`. Ruby 1.8 stops with a SyntaxError on it.
    /// `codeOnly` keeps the `#` of a comment, so a comment can sit
    /// between `do` and the `|`.
    private static let blockParameterDefault = try? NSRegularExpression(
        pattern: #"(?:\bdo|\{)[\s#]*\|[^|]*\b\w+\s*=(?![=~>])[^|]*\|"#)

    private static func startsFrozen(_ script: String) -> Bool {
        for line in script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if frozenStringLiteral?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            {
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") { return false }
        }
        return false
    }

    /// The source with comments and the plain part of string literals
    /// and heredoc bodies replaced by spaces. Almost Heroic lists `font:, value:`
    /// in a comment, which reads as keyword-arg shorthand. A quoted
    /// string over several lines stays code, because one misread quote
    /// would hide the rest of every script. For the same reason, a
    /// heredoc counts only when its end line exists.
    private static func codeOnly(_ source: String) -> String {
        scanLines(source).map { line in
            line.kind == .skipped
                ? "" : String(line.units.indices.map { line.code[$0] ? line.units[$0] : " " })
        }.joined(separator: "\n")
    }

    private enum LineKind {
        case code
        case heredocBody
        /// A block comment line or a heredoc end line.
        case skipped
    }

    private struct ScannedLine {
        let text: String
        let units: [Character]
        /// True at each UTF-16 unit that Ruby reads as code.
        let code: [Bool]
        let kind: LineKind
    }

    /// Splits a script into lines and follows its block comments and
    /// heredocs, so every scan reads the same characters as code.
    private static func scanLines(_ source: String) -> [ScannedLine] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Ruby needs the end line of a heredoc. With no end line after
        // it, `value <<token` is a shift.
        var lastLine: [String: Int] = [:]
        var lastIndentlessLine: [String: Int] = [:]
        for (number, line) in lines.enumerated() {
            lastLine[line] = number
            lastIndentlessLine[String(withoutIndent(line))] = number
        }
        var inBlockComment = false
        var heredocs: [(end: String, indented: Bool, interpolates: Bool)] = []
        var bodyStack = heredocBody
        return lines.enumerated().map { number, line in
            let units = line.utf16.map { Character(Unicode.Scalar($0) ?? "\u{FFFD}") }
            let noCode = [Bool](repeating: false, count: units.count + 1)
            if let open = heredocs.first {
                if (open.indented ? withoutIndent(line) : line[...]) == open.end {
                    heredocs.removeFirst()
                    bodyStack = heredocBody
                    return ScannedLine(text: line, units: units, code: noCode, kind: .skipped)
                }
                let code = open.interpolates ? codeMask(units, stack: &bodyStack) : noCode
                return ScannedLine(text: line, units: units, code: code, kind: .heredocBody)
            }
            if startsDirective(line, "=begin") { inBlockComment = true }
            if inBlockComment {
                // Ruby also ignores the rest of the `=end` line.
                if startsDirective(line, "=end") { inBlockComment = false }
                return ScannedLine(text: line, units: units, code: noCode, kind: .skipped)
            }
            let code = codeMask(units)
            let range = NSRange(line.startIndex..., in: line)
            for match in heredocStart?.matches(in: line, range: range) ?? [] where code[match.range.location]
            {
                func group(_ number: Int) -> Substring {
                    Range(match.range(at: number), in: line).map { line[$0] } ?? ""
                }
                let end = String(group(3))
                let indented = !group(1).isEmpty
                if ((indented ? lastIndentlessLine[end] : lastLine[end]) ?? -1) > number {
                    heredocs.append((end, indented, group(2) != "'"))
                }
            }
            return ScannedLine(text: line, units: units, code: code, kind: .code)
        }
    }

    /// `prepend` is `String#prepend` (1.9.3) or `Module#prepend` (2.0).
    /// The `def` check comes after `.prepend`. Before it, ICU runs the
    /// look-behind at every character, 40 times slower on a 1 MB line.
    private static let ruby19Call = try? NSRegularExpression(
        pattern:
            #"\.force_encoding\b|\bEncoding::[A-Z]|\.prepend\b(?<!\bdef\s{1,8}[\w:]{1,64}\.prepend)|(?:^|(?<=;))\s*prepend[\s(]+(?:::)?[A-Z]"#
    )

    /// Only an `if` or `elsif` that checks for 1.9 directly. A negated
    /// check, `unless`, `else`, or an `||` / `or` in the condition runs
    /// its body on 1.8. So does a comparison such as `vxace? == false`.
    /// Group 1 is the receiver of `respond_to?`, and group 2 is the
    /// method that it checks.
    /// Zeus81's `vxace?` is false only on RPG Maker XP's own Ruby 1.8.1.
    /// On Empo's 1.8.8 it is true and a 1.9 call under it raises, but
    /// Pokemon Xenoverse ships these scripts and runs on Ruby 1.8.7 in
    /// its own engine.
    private static let ruby19Guard = try? NSRegularExpression(
        pattern:
            #"\b(?:if|elsif)\s+\(?\s*(?:(?:([@$]?[\w.:]+)\.)?respond_to\?[\s(]*:(force_encoding|prepend)\b|defined\?[\s(]*Encoding\b|vxace\?(?:\(\s*\))?+(?![\s)]*[=!]=))(?![^#;]*(?:\|\||\bor\b))"#
    )

    private static let branchBlockStart = try? NSRegularExpression(
        pattern: #";\s*(?:begin|case|if|unless|while|until)\b|\bdo\b"#)

    /// A `<<` right after a value, as in `i<<x` or `(1<<n)`, is a shift.
    private static let heredocStart = try? NSRegularExpression(
        pattern: #"(?<![\w)\]}"'`])<<([-~]?)(["'`]?)([A-Za-z_]\w*)\2"#)

    /// What a guard makes safe: every 1.9 call after `defined?(Encoding)`,
    /// or only the method and the receiver that `respond_to?` checked.
    private enum Cover: Equatable {
        case all
        case call(receiver: String, method: String)
    }

    /// Scripts written for both 1.8 and 1.9 check for the method first,
    /// in a postfix `if` on the same statement or in an `if` block, so
    /// those calls do not count.
    private static func callsRuby19Methods(_ source: String) -> Bool {
        guard let ruby19Call, let ruby19Guard else { return false }
        func covered(_ call: NSRange, in units: [Character], by covers: [Cover]) -> Bool {
            if covers.contains(.all) { return true }
            let text = String(units[call.location..<call.location + call.length])
                .trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(".") else {
                return text.hasPrefix("prepend")
                    && covers.contains(.call(receiver: "self", method: "prepend"))
            }
            var start = call.location
            while start > 0,
                units[start - 1].isLetter || units[start - 1].isNumber
                    || "_.:@$".contains(units[start - 1])
            {
                start -= 1
            }
            let receiver = String(units[start..<call.location])
            let method = String(text.dropFirst())
            return covers.contains(.call(receiver: receiver.isEmpty ? "self" : receiver, method: method))
        }
        func codeMatches(_ regex: NSRegularExpression, in scanned: ScannedLine) -> [NSTextCheckingResult] {
            regex.matches(in: scanned.text, range: NSRange(scanned.text.startIndex..., in: scanned.text))
                .filter { scanned.code[$0.range.location] }
        }
        func cover(of match: NSTextCheckingResult, in line: String) -> Cover {
            guard let method = Range(match.range(at: 2), in: line) else { return .all }
            let receiver = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? "self"
            return .call(receiver: receiver, method: String(line[method]))
        }
        // `when 2; begin` opens a block of its own, so the search stops there.
        func branchOpensNoBlock(_ text: String) -> Bool {
            branchBlockStart?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
        }
        func indent(of line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        func closes(_ text: String) -> Bool {
            ["end", "else", "elsif"].contains { text.hasPrefix($0) }
        }
        let lines = scanLines(source)
        // In `case ... end if vxace?`, the guard on the end line covers the
        // `case` or `begin` block at the same indent.
        var endGuards = [[Cover]](repeating: [], count: lines.count)
        for (number, scanned) in lines.enumerated() where scanned.kind == .code {
            let line = scanned.text
            let covers = codeMatches(ruby19Guard, in: scanned)
                .filter {
                    (line as NSString).substring(to: $0.range.location).trimmingCharacters(in: .whitespaces)
                        == "end"
                }
                .map { cover(of: $0, in: line) }
            guard !covers.isEmpty else { continue }
            let opener = lines[..<number].lastIndex { candidate in
                let text = candidate.text.trimmingCharacters(in: .whitespaces)
                return candidate.kind == .code
                    && candidate.units.indices.contains {
                        candidate.code[$0] && !candidate.units[$0].isWhitespace && candidate.units[$0] != "#"
                    }
                    && indent(of: candidate.text) <= indent(of: line)
                    && !(["when", "else", "elsif", "rescue", "ensure"].contains { startsDirective(text, $0) }
                        && branchOpensNoBlock(text))
            }
            guard let opener, indent(of: lines[opener].text) == indent(of: line),
                ["case", "begin"].contains(where: {
                    startsDirective(String(withoutIndent(lines[opener].text)), $0)
                })
            else { continue }
            for inside in opener..<number { endGuards[inside] += covers }
        }
        var blocks: [(indent: Int, cover: Cover)] = []
        for (number, scanned) in lines.enumerated() {
            let line = scanned.text
            let units = scanned.units
            switch scanned.kind {
            case .skipped:
                continue
            case .heredocBody:
                if codeMatches(ruby19Call, in: scanned).contains(where: {
                    !covered($0.range, in: units, by: blocks.map(\.cover) + endGuards[number])
                }) {
                    return true
                }
                continue
            case .code:
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIndent = indent(of: line)
            if let last = blocks.last, lineIndent == last.indent && closes(trimmed) {
                blocks.removeLast()
            }
            let guards = codeMatches(ruby19Guard, in: scanned)
            let calls = codeMatches(ruby19Call, in: scanned)
            var inline: [Cover] = []
            var start = 0
            let ends = units.indices.filter { units[$0] == ";" && scanned.code[$0] } + [units.count]
            for (segment, end) in ends.enumerated() {
                defer { start = end + 1 }
                let text = String(units[start..<end]).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty && closes(text) { inline.removeAll() }
                let own = guards.filter { (start..<end).contains($0.range.location) }.map {
                    cover(of: $0, in: line)
                }
                let covers = blocks.map(\.cover) + endGuards[number] + inline + own
                let open = calls.filter { (start..<end).contains($0.range.location) }
                if open.contains(where: { !covered($0.range, in: units, by: covers) }) { return true }
                let opensBlock = text.hasPrefix("if ") || text.hasPrefix("elsif ")
                guard opensBlock && !text.hasSuffix("end"), !own.isEmpty else { continue }
                if segment == ends.count - 1 {
                    blocks += own.map { (lineIndent, $0) }
                } else {
                    inline += own
                }
            }
        }
        return false
    }

    private static func withoutIndent(_ line: String) -> Substring {
        line.drop { $0 == " " || $0 == "\t" }
    }

    private static func startsDirective(_ line: String, _ name: String) -> Bool {
        line.hasPrefix(name) && (line.dropFirst(name.count).first?.isWhitespace ?? true)
    }

    private enum Scope {
        case literal(open: Character?, close: Character, interpolates: Bool, depth: Int)
        case insert(braces: Int)
    }

    /// For each UTF-16 unit of a line, true when it sits outside a comment
    /// and outside the plain part of a string literal. Code inside a
    /// `#{...}` insert counts.
    private static func codeMask(_ chars: [Character]) -> [Bool] {
        var stack: [Scope] = []
        return codeMask(chars, stack: &stack)
    }

    /// The state at the start of an interpolating heredoc body. Pass the
    /// same stack for every body line, so a `#{...}` can span lines.
    private static let heredocBody: [Scope] = [.literal(open: nil, close: "\n", interpolates: true, depth: 0)]

    private static func codeMask(_ chars: [Character], stack: inout [Scope]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count + 1)
        var index = 0
        func isCode() -> Bool {
            if case .literal? = stack.last { return false }
            return true
        }
        while index < chars.count {
            mask[index] = isCode()
            let char = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            index += 1
            if case .literal(let open, let close, let interpolates, let depth)? = stack.last {
                if char == "\\" {
                    index += 1
                } else if char == open {
                    stack[stack.count - 1] = .literal(
                        open: open, close: close, interpolates: interpolates, depth: depth + 1)
                } else if char == close && depth > 0 {
                    stack[stack.count - 1] = .literal(
                        open: open, close: close, interpolates: interpolates, depth: depth - 1)
                } else if char == close {
                    stack.removeLast()
                } else if interpolates && char == "#" && next == "{" {
                    stack.append(.insert(braces: 0))
                    index += 1
                }
                continue
            }
            switch char {
            case "\"":
                stack.append(.literal(open: nil, close: "\"", interpolates: true, depth: 0))
            case "'":
                stack.append(.literal(open: nil, close: "'", interpolates: false, depth: 0))
            case "`":
                stack.append(.literal(open: nil, close: "`", interpolates: true, depth: 0))
            case "%":
                if let literal = percentLiteral(chars, at: &index) { stack.append(literal) }
            case "/":
                if startsRegex(chars, before: index - 1) {
                    stack.append(.literal(open: nil, close: "/", interpolates: true, depth: 0))
                }
            case "#":
                return mask
            case "{":
                if case .insert(let braces)? = stack.last {
                    stack[stack.count - 1] = .insert(braces: braces + 1)
                }
            case "}":
                if case .insert(let braces)? = stack.last {
                    if braces == 0 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .insert(braces: braces - 1)
                    }
                }
            default:
                break
            }
        }
        mask[chars.count] = isCode()
        return mask
    }

    /// A `/` opens a regex where a value can start, and divides after a
    /// value: `gsub!(/<<r>>/, "")` against `width/2`. As in Ruby, a name,
    /// a space, and a `/` with no space after it is a call with a regex:
    /// `text.scan /<<tag>>/`. Ruby reads it as division when the name is
    /// a local variable, so with no closing `/` on the line it divides:
    /// `width /3`.
    private static func startsRegex(_ chars: [Character], before slash: Int) -> Bool {
        var cursor = slash
        while cursor > 0, chars[cursor - 1] == " " || chars[cursor - 1] == "\t" { cursor -= 1 }
        let next: Character = slash + 1 < chars.count ? chars[slash + 1] : " "
        let callArgument =
            cursor < slash && !next.isWhitespace && next != "="
            && closesRegex(chars, after: slash)
        guard cursor > 0 else { return true }
        let previous = chars[cursor - 1]
        if "(,=!~|&{[;?:+-*<>^".contains(previous) { return true }
        guard previous.isLetter || previous == "_" else { return false }
        var start = cursor - 1
        while start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber || chars[start - 1] == "_" {
            start -= 1
        }
        let keywords: Set<String> = [
            "if", "elsif", "unless", "when", "while", "until", "and", "or", "not", "return", "then",
        ]
        return callArgument || keywords.contains(String(chars[start..<cursor]))
    }

    private static func closesRegex(_ chars: [Character], after slash: Int) -> Bool {
        var index = slash + 1
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == "/" { return true }
            index += 1
        }
        return false
    }

    /// Reads a `%q(...)`-style literal start after the `%`. A `%` with
    /// a space, a letter, or `=` after it is the modulo operator, and so
    /// is a `%` right after a value or a dot, as in `a%(b)`, `"%s"%(b)`,
    /// or `a.%(b)`. Outside
    /// a literal, a quote before the `%` can only close one.
    private static func percentLiteral(_ chars: [Character], at index: inout Int) -> Scope? {
        if index >= 2 {
            let before = chars[index - 2]
            if before.isLetter || before.isNumber || "_.)]}\"'`".contains(before) { return nil }
        }
        if index < chars.count, chars[index] == "=" { return nil }
        var cursor = index
        var kind: Character?
        if cursor < chars.count, "qQwWiIrsx".contains(chars[cursor]) {
            kind = chars[cursor]
            cursor += 1
        }
        guard cursor < chars.count else { return nil }
        let delimiter = chars[cursor]
        guard !delimiter.isLetter, !delimiter.isNumber, !delimiter.isWhitespace else { return nil }
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
        index = cursor + 1
        return .literal(
            open: pairs[delimiter] == nil ? nil : delimiter,
            close: pairs[delimiter] ?? delimiter,
            interpolates: !"qwis".contains(kind ?? "Q"),
            depth: 0)
    }
}

// MARK: - Marshal reader

/// Minimal Ruby Marshal reader. It implements only what the RPG
/// Maker Scripts file needs: the version header, fixed-size
/// positive longs, bare strings, ivar-wrapped strings, and skips
/// for integers, symbols, and arrays. On an unknown tag it stops,
/// and the caller treats that as inconclusive.
///
/// Reference: Ruby's Marshal format at doc/marshal.rdoc.
private struct MarshalReader {
    let data: Data
    var pos: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readByte() -> UInt8? {
        guard pos < data.count else { return nil }
        let b = data[pos]
        pos += 1
        return b
    }

    /// The Marshal version is 2 bytes (major, minor). Current
    /// Ruby emits 4.8. We accept any 4.x.
    mutating func readVersion() -> Bool {
        guard let major = readByte(), readByte() != nil else { return false }
        return major == 4
    }

    mutating func expect(_ tag: UInt8) -> Bool {
        guard let b = readByte() else { return false }
        return b == tag
    }

    /// Marshal long-encoded integer. The reader interprets the
    /// byte b as:
    ///   b == 0      -> 0
    ///   b in 1..4   -> next b bytes little-endian unsigned
    ///   b in -4..-1 -> next |b| bytes, sign-extended negative
    ///   b >= 5      -> small positive: (b - 5)
    ///   b <= -5     -> small negative: (b + 5)
    mutating func readLong() -> Int? {
        guard let raw = readByte() else { return nil }
        let signed = Int8(bitPattern: raw)
        if signed == 0 { return 0 }
        if signed > 0 && signed < 5 {
            var x = 0
            for i in 0..<Int(signed) {
                guard let b = readByte() else { return nil }
                x |= Int(b) << (8 * i)
            }
            return x
        }
        if signed < 0 && signed > -5 {
            let n = -Int(signed)
            var x = -1
            for i in 0..<n {
                guard let b = readByte() else { return nil }
                x &= ~(0xff << (8 * i))
                x |= Int(b) << (8 * i)
            }
            return x
        }
        if signed > 4 {
            return Int(signed) - 5
        }
        return Int(signed) + 5
    }

    /// Reads a string's raw byte payload. The reader unwraps the
    /// `I` ivar wrapper that Ruby uses to attach encoding
    /// metadata. We do not need the encoding tag. We only want
    /// the bytes.
    mutating func readStringBytes() -> Data? {
        guard let tag = readByte() else { return nil }
        if tag == 0x49 {  // 'I' = ivar wrapper
            guard let inner = readByte(), inner == 0x22 else { return nil }  // '"'
            guard let bytes = readRawString() else { return nil }
            // Skip the ivars (the encoding flag and others). Each
            // ivar is [symbol, value]. skipValue handles both.
            guard let ivarCount = readLong(), ivarCount >= 0 else { return nil }
            for _ in 0..<ivarCount {
                guard skipValue() else { return nil }  // symbol
                guard skipValue() else { return nil }  // value
            }
            return bytes
        }
        if tag == 0x22 {  // '"' = bare string (no ivars)
            return readRawString()
        }
        return nil
    }

    /// Reads a Marshal string body without the leading tag byte:
    /// a length prefix, then that many bytes.
    private mutating func readRawString() -> Data? {
        readCountedBytes().map { data.subdata(in: $0) }
    }

    /// Reads a length prefix and moves past that many bytes. A
    /// negative length from the file would move the cursor back
    /// before the buffer, and the next read would trap.
    private mutating func readCountedBytes() -> Range<Int>? {
        guard let len = readLong(), len >= 0, len <= data.count - pos else {
            return nil
        }
        pos += len
        return (pos - len)..<pos
    }

    /// Real script archives nest 2 or 3 levels. A file of deeply nested
    /// arrays would overflow the stack.
    private static let maxDepth = 32

    /// Skips a complete Marshal value of any supported type. This
    /// discards fields we do not need (script id, title) and
    /// keeps the reader in sync with the byte stream. If the
    /// reader finds an unknown tag, it returns false. The result
    /// then becomes "inconclusive".
    mutating func skipValue(depth: Int = 0) -> Bool {
        guard depth < Self.maxDepth, let tag = readByte() else { return false }
        switch tag {
        case 0x30:  // '0' = nil
            return true
        case 0x54, 0x46:  // 'T' true, 'F' false
            return true
        case 0x69:  // 'i' = integer
            return readLong() != nil
        case 0x66, 0x22, 0x3a:  // 'f' float (string repr), '"' string, ':' symbol
            return readCountedBytes() != nil
        case 0x3b, 0x40:  // ';' symbol link, '@' object link
            return readLong() != nil
        case 0x49:  // 'I' = ivar wrapper
            guard skipValue(depth: depth + 1) else { return false }
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<n {
                guard skipValue(depth: depth + 1) else { return false }
                guard skipValue(depth: depth + 1) else { return false }
            }
            return true
        case 0x5b:  // '[' = array
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<n {
                guard skipValue(depth: depth + 1) else { return false }
            }
            return true
        case 0x7b:  // '{' = hash
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<(n * 2) {
                guard skipValue(depth: depth + 1) else { return false }
            }
            return true
        default:
            // Unknown or unsupported tag (object instances,
            // regexps, bignums). Stop here. The caller falls back
            // to the extension heuristic.
            return false
        }
    }
}
