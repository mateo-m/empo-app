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
        /// `force_encoding`. Ruby 1.8 lacks the methods, and plain
        /// Ruby 3.1 rejects the grammar, so only Ruby 3.1 with the
        /// legacy syntax transform runs it (Vinemon Sauce Edition).
        case mixed

        /// The sniffer could not read the live source. Causes: an
        /// encrypted archive with no unpack, a missing file, a
        /// parse error, an unknown Marshal tag, or scripts packed
        /// in a `Data/*.fpk` archive. The caller falls back to
        /// packaging signals, the extension, Game.ini, or the
        /// default.
        case inconclusive
    }

    /// Sniffs a game directory. The sniffer reads loose `.rb`
    /// files first. The mkxp-z runtime loads those on top of the
    /// compiled Scripts.rxdata, so they are the live source for
    /// forks that ship both. The sniffer then falls back to the
    /// compiled `Scripts.{rxdata,rvdata,rvdata2}` file, unless a
    /// packed script archive makes that file a stale bootstrap.
    /// It runs the grammar classifier on the joined source.
    static func sniff(gameDirectory: URL) -> Result {
        let fm = FileManager.default

        // Loose .rb files take priority. Forks like Pokemon Reborn
        // 19.5+ ship only loose scripts and no compiled file.
        // Forks like Pokemon Infinite Fusion ship loose scripts
        // next to a stale compiled Scripts.rxdata. The loose files
        // are the live runtime. The .rxdata is a leftover.
        let looseURLs = locateLooseScripts(in: gameDirectory, fm: fm)
        if !looseURLs.isEmpty {
            let source = readLooseScripts(urls: looseURLs)
            if !source.isEmpty {
                return classify(source: source)
            }
        }

        // Packed scripts. Post-2020 custom engines keep the real
        // scripts in a 7z `Data/*.fpk` archive and mount it at
        // run time (Pokemon Flux: `Data/Data_0.fpk`). The compiled
        // Scripts file next to it is a small bootstrap, not the
        // live source, so the sniffer must not classify it.
        if hasPackedScriptArchive(in: gameDirectory, fm: fm) {
            return .inconclusive
        }

        // Compiled Scripts file. Vanilla RPG Maker XP / VX /
        // VX Ace projects use it, and so do forks that did not
        // extract their scripts.
        guard let url = locateCompiledScriptsFile(in: gameDirectory, fm: fm) else {
            return .inconclusive
        }
        guard let source = decodeScripts(at: url) else {
            return .inconclusive
        }
        return classify(source: source)
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
    static func hasPackedScriptArchive(in gameDirectory: URL, fm: FileManager) -> Bool {
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

    /// Reads up to `maxLooseFiles` `.rb` files and joins them.
    /// A 4 MB cap on the total prevents one huge generated file
    /// from using too much memory.
    private static func readLooseScripts(urls: [URL]) -> String {
        var combined = ""
        let cap = 4_000_000
        for url in urls {
            guard let str = try? Data(contentsOf: url).decodeAsLooseText() else { continue }
            combined.append(str)
            combined.append("\n")
            if combined.utf8.count > cap { break }
        }
        return combined
    }

    // MARK: - Marshal + Zlib decode

    private static func decodeScripts(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var reader = MarshalReader(data: data)
        guard reader.readVersion() else { return nil }
        // The outer container is an array of script entries.
        guard reader.expect(0x5b) else { return nil }  // '['
        guard let count = reader.readLong(), count >= 0, count < 100_000 else {
            return nil
        }

        var combined = ""
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
                combined.append(source)
                combined.append("\n")
                if combined.utf8.count > combinedCap { break }
            }
        }
        return combined.isEmpty ? nil : combined
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
        // Hash#except (3.0+): h.except(:k)
        #"\.except\s*\("#,
        // Array#filter_map (2.7+): arr.filter_map { ... }
        #"\.filter_map\b"#,
        // Object#then or yield_self (2.5+/2.6+): obj.then { ... }
        #"\.then\s*\{\s*\|"#,
        // Frozen-string-literal magic comment (2.3+, common in
        // modern code): # frozen_string_literal: true
        #"#\s*frozen_string_literal:\s*true"#,
    ]

    /// Threshold to declare the source modern. A single match can
    /// come from a comment, an embedded test fixture, or chance.
    /// Three or more tokens across the whole source is a strong
    /// signal.
    private static let modernThreshold = 3

    private static func classify(source: String) -> Result {
        var hits = 0
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for pattern in modernTokens {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.anchorsMatchLines]
                )
            else { continue }
            hits += regex.numberOfMatches(in: source, options: [], range: range)
            if hits >= modernThreshold { return .modern }
        }
        return callsRuby19Methods(source) ? .mixed : .legacy
    }

    private static let ruby19Call = try? NSRegularExpression(
        pattern: #"\.force_encoding\b|\bEncoding::[A-Z]"#)

    /// Only an `if` or `elsif` that checks for 1.9 directly. A negated
    /// check, `unless`, `else`, or an `||` / `or` in the condition runs
    /// its body on 1.8. Group 1 is the receiver of `respond_to?`.
    private static let ruby19Guard = try? NSRegularExpression(
        pattern: #"\b(?:if|elsif)\s+\(?\s*(?:(?:([@$]?[\w.]+)\.)?respond_to\?[\s(]*:force_encoding\b|defined\?[\s(]*Encoding\b)(?![^#;]*(?:\|\||\bor\b))"#)

    private static let heredocStart = try? NSRegularExpression(
        pattern: #"<<([-~]?)(["'`]?)([A-Za-z_]\w*)\2"#)

    /// What a guard makes safe: every 1.9 call after `defined?(Encoding)`,
    /// or only `force_encoding` on the receiver that `respond_to?` checked.
    private enum Cover: Equatable {
        case all
        case receiver(String)
    }

    /// Scripts written for both 1.8 and 1.9 check for the method first,
    /// in a postfix `if` on the same statement or in an `if` block, so
    /// those calls do not count.
    private static func callsRuby19Methods(_ source: String) -> Bool {
        guard let ruby19Call, let ruby19Guard, let heredocStart else { return false }
        func covered(_ call: NSRange, in units: [Character], by covers: [Cover]) -> Bool {
            if covers.contains(.all) { return true }
            guard units[call.location] == "." else { return false }
            var start = call.location
            while start > 0, units[start - 1].isLetter || units[start - 1].isNumber
                || "_.@$".contains(units[start - 1]) {
                start -= 1
            }
            let receiver = String(units[start..<call.location])
            return covers.contains(.receiver(receiver.isEmpty ? "self" : receiver))
        }
        var inBlockComment = false
        var heredoc: (end: String, indented: Bool, interpolates: Bool)?
        var blocks: [(indent: Int, cover: Cover)] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let units = line.utf16.map { Character(Unicode.Scalar($0) ?? "\u{FFFD}") }
            let range = NSRange(line.startIndex..., in: line)
            if let open = heredoc {
                if (open.indented ? trimmed : line) == open.end {
                    heredoc = nil
                } else if open.interpolates {
                    let code = codeMask(units, inString: true)
                    let calls = ruby19Call.matches(in: line, range: range).filter { code[$0.range.location] }
                    if calls.contains(where: { !covered($0.range, in: units, by: blocks.map(\.cover)) }) {
                        return true
                    }
                }
                continue
            }
            if line.hasPrefix("=begin") { inBlockComment = true }
            if line.hasPrefix("=end") { inBlockComment = false }
            if inBlockComment { continue }
            let code = codeMask(units)
            func codeMatches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
                regex.matches(in: line, range: range).filter { code[$0.range.location] }
            }
            if let match = codeMatches(heredocStart).first {
                func group(_ number: Int) -> Substring {
                    Range(match.range(at: number), in: line).map { line[$0] } ?? ""
                }
                heredoc = (String(group(3)), !group(1).isEmpty, group(2) != "'")
            }
            func closes(_ text: String) -> Bool {
                ["end", "else", "elsif"].contains { text.hasPrefix($0) }
            }
            if let last = blocks.last, indent == last.indent && closes(trimmed) {
                blocks.removeLast()
            }
            let guards = codeMatches(ruby19Guard)
            let calls = codeMatches(ruby19Call)
            var inline: [Cover] = []
            var start = 0
            let ends = units.indices.filter { units[$0] == ";" && code[$0] } + [units.count]
            for (number, end) in ends.enumerated() {
                defer { start = end + 1 }
                let text = String(units[start..<end]).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty && closes(text) { inline.removeAll() }
                let own = guards.filter { (start..<end).contains($0.range.location) }.map { match in
                    Range(match.range(at: 1), in: line).map { Cover.receiver(String(line[$0])) }
                        ?? (line[Range(match.range, in: line)!].contains("respond_to") ? .receiver("self") : .all)
                }
                let covers = blocks.map(\.cover) + inline + own
                let open = calls.filter { (start..<end).contains($0.range.location) }
                if open.contains(where: { !covered($0.range, in: units, by: covers) }) { return true }
                let opensBlock = text.hasPrefix("if ") || text.hasPrefix("elsif ")
                guard opensBlock && !text.hasSuffix("end"), !own.isEmpty else { continue }
                if number == ends.count - 1 {
                    blocks += own.map { (indent, $0) }
                } else {
                    inline += own
                }
            }
        }
        return false
    }

    private enum Scope {
        case literal(open: Character?, close: Character, interpolates: Bool, depth: Int)
        case insert(braces: Int)
    }

    /// For each UTF-16 unit of a line, true when it sits outside a comment
    /// and outside the plain part of a string literal. Code inside a
    /// `#{...}` insert counts. `inString` starts inside a heredoc body.
    private static func codeMask(_ chars: [Character], inString: Bool = false) -> [Bool] {
        var stack: [Scope] = inString
            ? [.literal(open: nil, close: "\n", interpolates: true, depth: 0)] : []
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
            case "%":
                if let literal = percentLiteral(chars, at: &index) { stack.append(literal) }
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

    /// Reads a `%q(...)`-style literal start after the `%`. A `%` with
    /// a space or a letter after it is the modulo operator.
    private static func percentLiteral(_ chars: [Character], at index: inout Int) -> Scope? {
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
            guard let ivarCount = readLong() else { return nil }
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
        guard let len = readLong(), len >= 0, pos + len <= data.count else {
            return nil
        }
        let bytes = data.subdata(in: pos..<(pos + len))
        pos += len
        return bytes
    }

    /// Skips a complete Marshal value of any supported type. This
    /// discards fields we do not need (script id, title) and
    /// keeps the reader in sync with the byte stream. If the
    /// reader finds an unknown tag, it returns false. The result
    /// then becomes "inconclusive".
    mutating func skipValue() -> Bool {
        guard let tag = readByte() else { return false }
        switch tag {
        case 0x30:  // '0' = nil
            return true
        case 0x54, 0x46:  // 'T' true, 'F' false
            return true
        case 0x69:  // 'i' = integer
            return readLong() != nil
        case 0x66:  // 'f' = float (string repr)
            return readLong().map { len in
                pos += len
                return pos <= data.count
            } ?? false
        case 0x22, 0x3a:  // '"' string, ':' symbol
            guard let len = readLong(), len >= 0, pos + len <= data.count else {
                return false
            }
            pos += len
            return true
        case 0x3b, 0x40:  // ';' symbol link, '@' object link
            return readLong() != nil
        case 0x49:  // 'I' = ivar wrapper
            guard skipValue() else { return false }
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<n {
                guard skipValue() else { return false }
                guard skipValue() else { return false }
            }
            return true
        case 0x5b:  // '[' = array
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<n {
                guard skipValue() else { return false }
            }
            return true
        case 0x7b:  // '{' = hash
            guard let n = readLong(), n >= 0 else { return false }
            for _ in 0..<(n * 2) {
                guard skipValue() else { return false }
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
