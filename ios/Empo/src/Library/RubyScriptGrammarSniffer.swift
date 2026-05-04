import Compression
import Foundation

/// Decodes RPG Maker `Scripts.{rxdata,rvdata,rvdata2}` files (Ruby
/// Marshal envelope around zlib-deflated source per script entry)
/// and classifies the contained Ruby source as modern (3.x grammar)
/// or legacy (1.8/1.9 grammar).
///
/// Used by `RubyVersionDetection` to tell apart vanilla RPG Maker
/// games (where extension pins Ruby version) from forks that ship
/// the original RGSS data layout but ported their scripts to modern
/// Ruby grammar (Pokemon Reborn 19.5+, Pokemon Essentials v20+,
/// etc).
///
/// The Marshal mini-decoder handles only the narrow subset RPG
/// Maker emits: outer Array of 3-tuples [Integer, String, String]
/// where the third String is zlib-deflated Ruby source. Anything
/// outside that subset → bail, return `.inconclusive`. Detection's
/// caller treats `.inconclusive` as "fall back to extension or
/// default" so any decoder bug is non-fatal.
enum RubyScriptGrammarSniffer {

    enum Result {
        /// Modern Ruby grammar tokens present (`&.`, kwargs,
        /// pattern matching, endless def, etc). Cannot parse on
        /// 1.8/1.9 - definitive signal for 3.x dispatch.
        case modern

        /// Successfully read script source but found no modern
        /// tokens. Caller should use the data file extension as
        /// the prior to choose between 1.8 (`.rxdata`) and 1.9
        /// (`.rvdata`/`.rvdata2`).
        case legacy

        /// Could not read or decode Scripts file (encrypted
        /// archive without unpack, missing file, parse error,
        /// unknown Marshal tag). Caller falls back to extension /
        /// Game.ini / default.
        case inconclusive
    }

    /// Sniff a game directory. Reads loose `.rb` files first
    /// (mkxp-z runtime loads those on top of the compiled
    /// Scripts.rxdata, so they're the authoritative source for
    /// forks that ship both), then falls back to the compiled
    /// `Scripts.{rxdata,rvdata,rvdata2}` file. Runs the grammar
    /// classifier on the concatenated source.
    static func sniff(gameDirectory: URL) -> Result {
        let fm = FileManager.default

        // Loose .rb files take priority. Forks like Pokemon Reborn
        // 19.5+ ship ONLY loose scripts (no compiled file).
        // Forks like Pokemon Infinite Fusion ship loose scripts
        // alongside a stale compiled Scripts.rxdata; the loose
        // files are the live runtime, the .rxdata is vestigial.
        let looseURLs = locateLooseScripts(in: gameDirectory, fm: fm)
        if !looseURLs.isEmpty {
            let source = readLooseScripts(urls: looseURLs)
            if !source.isEmpty {
                return classify(source: source)
            }
        }

        // Compiled Scripts file. Used by vanilla RPG Maker XP /
        // VX / VX Ace projects and by forks that haven't extracted
        // their scripts.
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

    private static let looseScriptDirs = [
        "Scripts",
        "Data/Scripts",
    ]

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

    /// Walk `Scripts/` and `Data/Scripts/` looking for `.rb`
    /// files. Caps at `maxLooseFiles` so a pathological project
    /// with thousands of scripts can't make sniffing slow.
    private static let maxLooseFiles = 200

    private static func locateLooseScripts(
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
            // Recursive enumerator picks up nested per-feature
            // folders that some forks use (e.g. Plugins layout).
            guard
                let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "rb" {
                    found.append(url)
                    if found.count >= maxLooseFiles { return found }
                }
            }
        }
        return found
    }

    /// Read up to `maxLooseFiles` `.rb` files and concatenate.
    /// Cap at 4 MB combined so a single huge generated file can't
    /// blow memory.
    private static func readLooseScripts(urls: [URL]) -> String {
        var combined = ""
        let cap = 4_000_000
        for url in urls {
            guard let str = try? Data(contentsOf: url).decodeAsLooseText() else { continue }
            combined.append(str)
            combined.append("\n")
            if combined.count > cap { break }
        }
        return combined
    }

    // MARK: - Marshal + Zlib decode

    private static func decodeScripts(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var reader = MarshalReader(data: data)
        guard reader.readVersion() else { return nil }
        // Outer container is an array of script entries.
        guard reader.expect(0x5b) else { return nil }  // '['
        guard let count = reader.readLong(), count >= 0, count < 100_000 else {
            return nil
        }

        var combined = ""
        // Cap aggregate inflated source so a corrupted file with a
        // huge claimed count can't run us out of memory. 4 MB is
        // ~10x larger than the biggest real-world Scripts file we've
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
                if combined.count > combinedCap { break }
            }
        }
        return combined.isEmpty ? nil : combined
    }

    /// Zlib inflate. Compression.framework's COMPRESSION_ZLIB is
    /// raw deflate (no zlib header), so strip the 2-byte zlib
    /// header (typically 0x78 0x9c) before decoding.
    private static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let raw = data.dropFirst(2)
        // Output buffer sized at 16x input as a starting guess.
        // Real script source compresses ~3-4x so 16x covers all
        // real-world cases. If compression_decode_buffer fills the
        // buffer we'd lose the tail, but at 16x that won't happen
        // for any sane input.
        let bufferSize = max(raw.count * 16, 65_536)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        let written = raw.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                dst, bufferSize, base, raw.count, nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }

    // MARK: - Grammar classifier

    /// Patterns whose presence implies Ruby >= 3.0 grammar (or at
    /// minimum >= 2.x for some). Each is an NSRegularExpression
    /// pattern; matches across the concatenated script source.
    ///
    /// The set is conservative - every entry should be a token
    /// that a 1.8/1.9 parser literally cannot parse, not just one
    /// that's stylistically modern. False positives here = wrongly
    /// tagging a vanilla 1.8 game as modern → game wouldn't boot.
    private static let modernTokens: [String] = [
        // Safe call (2.3+): foo&.bar
        #"&\."#,
        // Pattern matching (3.0+): case x; in [a, *]
        #"\bcase\b\s+\S+[\s\S]{0,400}?\bin\b\s*[\[\{\(\w]"#,
        // Endless method def (3.0+): def foo = bar
        #"\bdef\s+\w+(\([^)]*\))?\s*=\s*\S"#,
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
        // Frozen-string-literal magic comment (2.3+, ubiquitous in
        // modern code): # frozen_string_literal: true
        #"#\s*frozen_string_literal:\s*true"#,
    ]

    /// Threshold for declaring source modern. Single matches could
    /// be in comments, embedded test fixtures, or coincidence; 3+
    /// tokens across the whole script source is a strong signal.
    private static let modernThreshold = 3

    private static func classify(source: String) -> Result {
        var hits = 0
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for pattern in modernTokens {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            hits += regex.numberOfMatches(in: source, options: [], range: range)
            if hits >= modernThreshold { return .modern }
        }
        return .legacy
    }
}

// MARK: - Marshal reader

/// Minimal Ruby Marshal reader. Implements only what's needed for
/// RPG Maker's Scripts file: version header, fixed-size positive
/// longs, bare strings, ivar-wrapped strings, integer/symbol/array
/// skipping. Bails on any unknown tag - caller treats that as
/// inconclusive.
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

    /// Marshal version is 2 bytes (major, minor). Current Ruby
    /// emits 4.8; we accept any 4.x.
    mutating func readVersion() -> Bool {
        guard let major = readByte(), readByte() != nil else { return false }
        return major == 4
    }

    mutating func expect(_ tag: UInt8) -> Bool {
        guard let b = readByte() else { return false }
        return b == tag
    }

    /// Marshal long-encoded integer. The byte b is interpreted as:
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

    /// Read a string's raw byte payload, transparently unwrapping
    /// the `I` ivar wrapper that Ruby uses to attach encoding
    /// metadata. We don't care about the encoding tag for our use
    /// case; the bytes are what we want.
    mutating func readStringBytes() -> Data? {
        guard let tag = readByte() else { return nil }
        if tag == 0x49 {  // 'I' = ivar wrapper
            guard let inner = readByte(), inner == 0x22 else { return nil }  // '"'
            guard let bytes = readRawString() else { return nil }
            // Skip ivars (encoding flag and friends). Each ivar is
            // [symbol, value] - skipValue handles both.
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

    /// Read a Marshal string body (without the leading tag byte):
    /// length prefix + that many bytes.
    private mutating func readRawString() -> Data? {
        guard let len = readLong(), len >= 0, pos + len <= data.count else {
            return nil
        }
        let bytes = data.subdata(in: pos..<(pos + len))
        pos += len
        return bytes
    }

    /// Skip a complete Marshal value of any supported type. Used
    /// to discard fields we don't care about (script id, title)
    /// while staying in sync with the byte stream. Returns false
    /// if an unknown tag is encountered, which propagates up to
    /// "inconclusive".
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
            // Unknown / unsupported tag (object instances, regexps,
            // bignums, etc). Bail; caller falls back to extension
            // heuristic.
            return false
        }
    }
}
