import Foundation

/// Combined analysis of a game's script sources and runtime
/// markers. It replaces the parallel `RubyVersionDetection` and
/// `GameSettings.detectModernRubyScripts` sniffers. Ruby dispatch
/// and the syntax-transform mode now come from one profile result.
public enum GameScriptProfile {

    /// Schema version for the detection results stored on
    /// `GameMetadata`. If the heuristics change enough to
    /// re-classify imported games, bump this version.
    public enum Schema: String, Sendable {
        case initial = "initial"
        case bundledRubyDLL = "bundled-ruby-dll"
        case noStandaloneFramework = "no-standalone-framework"
        case dropRuby30 = "drop-ruby-30"
        case tightenGrammarSniff = "tighten-grammar-sniff"
        /// Unified profile module: one sniff drives the ruby version
        /// and the modern-script classification.
        case unified = "unified"
        /// Read script grammar outranks bundled-runtime packaging
        /// when the sniffer reached the source.
        case sourceOverPackaging = "source-over-packaging"
    }

    public static let currentSchema: Schema = .sourceOverPackaging

    public struct Result {
        public let rubyVersion: Int
        public let modernRubyScripts: Bool
        public let grammar: RubyScriptGrammarSniffer.Result
    }

    /// Analyzes `gameDirectory` once and returns Ruby dispatch and
    /// syntax-transform hints.
    public static func analyze(gameDirectory: URL) -> Result {
        let fm = FileManager.default
        let grammar = RubyScriptGrammarSniffer.sniff(gameDirectory: gameDirectory)
        let runtime = BundledRubyRuntime.scan(gameDirectory: gameDirectory, fm: fm)
        let rubyVersion = detectRubyVersion(
            gameDirectory: gameDirectory,
            grammar: grammar,
            runtime: runtime,
            fm: fm
        )
        let modern = detectModernRubyScripts(
            grammar: grammar,
            runtime: runtime,
            packedScripts: RubyScriptGrammarSniffer.hasPackedScriptArchive(
                in: gameDirectory, fm: fm)
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
        grammar: RubyScriptGrammarSniffer.Result,
        runtime: BundledRubyRuntime,
        fm: FileManager
    ) -> Int {
        if let bundledRuby = runtime.dispatchVersion {
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

    /// The read source outranks packaging. A bundled Ruby 3
    /// runtime says which interpreter the developer shipped, not
    /// which grammar the scripts use: old fangames repackaged on a
    /// modern mkxp-z build carry a Ruby 3 DLL next to 1.8-era
    /// source (Realidea System ships `x64-msvcrt-ruby300.dll` with
    /// `str[i]` byte reads) and need the legacy transform. So
    /// packaging only decides when the sniffer could not read the
    /// live source.
    private static func detectModernRubyScripts(
        grammar: RubyScriptGrammarSniffer.Result,
        runtime: BundledRubyRuntime,
        packedScripts: Bool
    ) -> Bool {
        switch grammar {
        case .modern:
            return true
        case .legacy:
            return false
        case .inconclusive:
            return runtime.embedsRuby3 || packedScripts
        }
    }

    // MARK: - Shared helpers

    /// What the game ships as its own Ruby runtime, read once from
    /// the libraries in the game root.
    struct BundledRubyRuntime {
        /// Dispatch version (18, 19, or 31) from a `*ruby<NNN>.dll`
        /// file name. Nil when no such file exists.
        let dispatchVersion: Int?
        /// True when any bundled `.dll`, `.dylib`, or `.so`
        /// carries the `"ruby 3."` version string. Modern custom
        /// engines ship their own runtime (Pokemon Flux's
        /// `x64-msvcrt-ruby310.dll`, macOS bundles'
        /// `libruby.3.x.dylib`). Renaming does not defeat it.
        /// Vanilla 1.8 and 1.9 binaries embed `"ruby 1.8."` or
        /// `"ruby 1.9."`, so RGSS1/2/3 games do not match.
        let embedsRuby3: Bool

        static let none = BundledRubyRuntime(dispatchVersion: nil, embedsRuby3: false)

        static func scan(gameDirectory: URL, fm: FileManager) -> BundledRubyRuntime {
            let libraries = gameDirectory.directoryEntries(
                matchingExtensions: ["dll", "dylib", "so"], fm: fm
            )
            guard !libraries.isEmpty else { return .none }
            return BundledRubyRuntime(
                dispatchVersion: dispatchVersion(in: libraries),
                embedsRuby3: embedsRuby3(in: libraries, fm: fm)
            )
        }

        private static func dispatchVersion(in libraries: [URL]) -> Int? {
            let pattern = #"(?i)(?:^|-|_)ruby(\d{3})\.dll$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            var bestMajor = -1
            var bestMinor = -1
            for url in libraries {
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
            default:
                return 31
            }
        }

        private static func embedsRuby3(in libraries: [URL], fm: FileManager) -> Bool {
            let modernRubyMarker = Data("ruby 3.".utf8)
            let scanBudget = 64 * 1024 * 1024
            for url in libraries {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                    let size = attrs[.size] as? Int,
                    size <= scanBudget,
                    let data = try? Data(contentsOf: url, options: .alwaysMapped)
                else { continue }
                if data.range(of: modernRubyMarker) != nil { return true }
            }
            return false
        }
    }

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
}
