import Foundation

/// Coordinated analysis of a game's script sources and runtime
/// markers. Replaces the parallel `RubyVersionDetection` +
/// `GameSettings.detectModernRubyScripts` sniffers so Ruby dispatch
/// and syntax-transform mode derive from one profile result.
public enum GameScriptProfile {

    /// Schema version for persisted detection results on
    /// `GameMetadata`. Bump when heuristics change enough to
    /// re-classify imported games.
    public enum Schema: String, Sendable {
        case initial = "initial"
        case bundledRubyDLL = "bundled-ruby-dll"
        case noStandaloneFramework = "no-standalone-framework"
        case dropRuby30 = "drop-ruby-30"
        case tightenGrammarSniff = "tighten-grammar-sniff"
        /// Unified profile module: one sniff drives ruby version +
        /// modern-script classification.
        case unified = "unified"
    }

    public static let currentSchema: Schema = .unified

    public struct Result {
        public let rubyVersion: Int
        public let modernRubyScripts: Bool
        public let grammar: RubyScriptGrammarSniffer.Result
    }

    /// Analyze `gameDirectory` once and return Ruby dispatch +
    /// syntax-transform hints.
    public static func analyze(gameDirectory: URL) -> Result {
        let grammar = RubyScriptGrammarSniffer.sniff(gameDirectory: gameDirectory)
        let rubyVersion = detectRubyVersion(
            gameDirectory: gameDirectory,
            grammar: grammar
        )
        let modern = detectModernRubyScripts(
            gameDirectory: gameDirectory,
            grammar: grammar
        )
        return Result(
            rubyVersion: rubyVersion,
            modernRubyScripts: modern,
            grammar: grammar
        )
    }

    // MARK: - Ruby version (formerly RubyVersionDetection)

    private static func detectRubyVersion(
        gameDirectory: URL,
        grammar: RubyScriptGrammarSniffer.Result
    ) -> Int {
        let fm = FileManager.default

        if let bundledRuby = bundledRubyDLLVersion(at: gameDirectory, fm: fm) {
            return bundledRuby
        }

        switch grammar {
        case .modern:
            return 31
        case .legacy:
            if let scriptVer = rubyVersionFromScriptExtension(
                at: gameDirectory, fm: fm
            ) {
                return scriptVer
            }
        case .inconclusive:
            break
        }

        if let archiveExt = topLevelRgssArchiveExtension(at: gameDirectory, fm: fm) {
            switch archiveExt {
            case "rgssad": return 18
            case "rgss2a": return 19
            case "rgss3a": return 19
            default: break
            }
        }

        if let libraryRGSS = rgssLibraryMajor(at: gameDirectory, fm: fm) {
            switch libraryRGSS {
            case 1: return 18
            case 2, 3: return 19
            default: break
            }
        }

        return 31
    }

    // MARK: - Modern Ruby scripts (formerly GameSettings)

    private static func detectModernRubyScripts(
        gameDirectory: URL,
        grammar: RubyScriptGrammarSniffer.Result
    ) -> Bool {
        if grammar == .modern { return true }

        let fm = FileManager.default

        let modernRubyMarker = Data("ruby 3.".utf8)
        let scanBudget = 64 * 1024 * 1024
        for url in gameDirectory.directoryEntries(
            matchingExtensions: ["dll", "dylib", "so"], fm: fm
        ) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? Int,
                size <= scanBudget,
                let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { continue }
            if data.range(of: modernRubyMarker) != nil { return true }
        }

        let dataDir = gameDirectory.appendingPathComponent("Data")
        if !dataDir.directoryEntries(matchingExtensions: ["fpk"], fm: fm).isEmpty {
            return true
        }

        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Scripts"),
            dataDir,
        ]

        let modernRegex = try? NSRegularExpression(
            pattern:
                "(?:^|(?<=[(,{]))\\s*[a-z_][a-zA-Z0-9_]*:\\s+(-?\\d|\"|'|\\[|\\{|true|false|nil|:[a-zA-Z_]|[a-z_])",
            options: [.anchorsMatchLines]
        )
        guard let regex = modernRegex else { return false }

        let scanCap = 2000
        for root in candidates {
            guard fm.fileExists(atPath: root.path),
                let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
            else { continue }

            var filesScanned = 0
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() != "rb" { continue }
                filesScanned += 1
                if filesScanned > scanCap { break }

                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }

                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Shared helpers

    private static func rubyVersionFromScriptExtension(
        at gameDirectory: URL,
        fm: FileManager
    ) -> Int? {
        let candidates = [
            gameDirectory,
            gameDirectory.appendingPathComponent("Data"),
        ]
        for dir in candidates {
            if fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rxdata").path) {
                return 18
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rvdata").path) {
                return 19
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rvdata2").path) {
                return 19
            }
        }
        return nil
    }

    private static func topLevelRgssArchiveExtension(
        at gameDirectory: URL,
        fm: FileManager
    ) -> String? {
        let entries = gameDirectory.directoryEntries(
            matchingExtensions: ["rgssad", "rgss2a", "rgss3a"],
            fm: fm
        )
        var best: String?
        var bestRank = 0
        for url in entries {
            let ext = url.pathExtension.lowercased()
            let rank: Int
            switch ext {
            case "rgssad": rank = 1
            case "rgss2a": rank = 2
            case "rgss3a": rank = 3
            default: continue
            }
            if rank > bestRank {
                bestRank = rank
                best = ext
            }
        }
        return best
    }

    private static func rgssLibraryMajor(
        at gameDirectory: URL,
        fm: FileManager
    ) -> Int? {
        let iniURL = gameDirectory.appendingPathComponent("Game.ini")
        guard
            let value = GameINI.parseINIValue(
                in: iniURL,
                section: "game",
                key: "library")
        else {
            return nil
        }
        let upper = value.uppercased()
        guard let range = upper.range(of: "RGSS") else { return nil }
        let after = upper[range.upperBound...]
        guard let firstDigit = after.first else { return nil }
        return firstDigit.hexDigitValue
    }

    private static func bundledRubyDLLVersion(
        at gameDirectory: URL,
        fm: FileManager
    ) -> Int? {
        let entries = gameDirectory.directoryEntries(
            matchingExtensions: ["dll"], fm: fm
        )
        let pattern = #"(?i)(?:^|-|_)ruby(\d{3})\.dll$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        var bestMajor = -1
        var bestMinor = -1
        for url in entries {
            let name = url.lastPathComponent
            let nsName = name as NSString
            let range = NSRange(location: 0, length: nsName.length)
            guard let m = regex.firstMatch(in: name, options: [], range: range),
                m.numberOfRanges >= 2
            else { continue }
            let digits = nsName.substring(with: m.range(at: 1))
            guard digits.count == 3,
                let major = Int(String(digits.first!)),
                let minor = Int(String(digits[digits.index(after: digits.startIndex)]))
            else {
                continue
            }
            if major > bestMajor || (major == bestMajor && minor > bestMinor) {
                bestMajor = major
                bestMinor = minor
            }
        }
        guard bestMajor >= 0 else { return nil }
        switch bestMajor {
        case 1:
            return bestMinor <= 8 ? 18 : 19
        case 2, 3:
            return 31
        default:
            return 31
        }
    }
}
