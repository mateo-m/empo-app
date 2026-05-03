import Foundation

/// Per-game Ruby interpreter version detection.
///
/// Multi-Ruby (Phase D in MULTI_RUBY_PLAN.md) ships separate native
/// libraries for each supported Ruby version (1.8, 1.9, 3.0, 3.1).
/// At import time we sniff the game folder for markers that indicate
/// which interpreter the game's source/bytecode targets. That value
/// is persisted on `metadata.rubyVersion` and read by
/// `AppState.selectGame` to call `mkxp_setActiveRubyVersion()` before
/// the engine boots.
///
/// JoiPlay's RPG Maker plugin uses the same dispatch model (verified
/// 2026-04-27 by inspecting `RPGMPlugin-1.22.00-patreon-release.apk`'s
/// `lib/arm64-v8a/`: `libmkxp18.so`, `libmkxp19.so`, `libmkxp30.so`).
/// JoiPlay caps at 3.0; we mirror their set + retain 3.1 during the
/// transition.
///
/// Detection priority order (first match wins):
///
    ///   1. PSDK markers (`Data/PSDK/`, `Data/Studio/`, `psdk/version.txt`,
    ///      `project.studio`, `pokemonsdk/`) → **3.0**.
    ///      PSDK is hard-pinned to Ruby 3.0.x; its precompiled `Game.yarb`
    ///      bytecode is strictly minor-version-locked.
    ///
    ///   2. Bundled `x64-msvcrt-rubyXXX.dll` / `msvcrt-rubyXXX.dll` /
    ///      `rubyXXX.dll` shipped alongside the game's executable. The
    ///      three-digit suffix encodes the Ruby version the developer
    ///      built and tested against. This is the strongest practical
    ///      signal for "modern PE forks built on mkxp-z" (Pokemon
    ///      Flux, Vanguard, Reborn, Infinite Fusion etc): they leave
    ///      `Game.ini`'s `Library=` field at the vestigial
    ///      `RGSS104E.dll` but the actual runtime is the bundled
    ///      modern Ruby DLL → **18 / 19 / 30 / 31** per filename.
    ///
    ///   3. JGP manifest declaring `runtime: "mkxp-z"` or `useModernRuby`
    ///      → **3.0** (matches mkxp-z upstream's pin and JoiPlay's
    ///      modern tier).
///
///   3. Modern-Ruby script syntax detected (Reborn 19.5+, PE v20+,
///      anything authored against modern Essentials) → **3.0**.
///      Reuses the existing `GameSettings.detectModernRubyScripts`
///      heuristic, which scans `.rb` files for keyword-arg shorthand
///      and other Ruby-3 syntax.
///
///   4. RGSS archive present:
///      - `*.rgssad` → **1.8** (RGSS1 / RPG Maker XP / Ruby 1.8.1)
///      - `*.rgss2a` → **1.9** (RGSS2 / RPG Maker VX / Ruby 1.9.2)
///      - `*.rgss3a` → **1.9** (RGSS3 / RPG Maker VX Ace / Ruby 1.9.2)
///
///   5. `Game.ini` `Library=` field:
///      - `RGSS104E.dll` → **1.8**
///      - `RGSS200.dll` / `RGSS202.dll` etc → **1.9**
///      - `RGSS300.dll` / `RGSS301.dll` etc → **1.9**
///
///   6. Default (unknown layout, or detection-skipped fallback) →
///      **3.1**, the build's legacy default. Once 3.1's merged.o
///      becomes the only path and detection is required, this
///      default goes away.
enum RubyVersionDetection {

    /// Identifies the heuristic set this build uses. Each new
    /// case is a strict superset of the previous one — adding a
    /// signal that re-classifies some already-imported games.
    /// `GameLibrary.buildGameEntry` re-runs detection whenever
    /// the stored `rubyVersionDetectedSchema` differs from
    /// `currentSchema.rawValue`, so users on an old install get
    /// upgraded the next time they open Empo.
    ///
    /// Stored on disk as a String (via `metadata.rubyVersion
    /// DetectedSchema`) instead of an enum directly. That keeps
    /// older Empo builds from crashing when reading metadata
    /// written by a newer build that introduced a case the old
    /// build doesn't know about — the unknown string just doesn't
    /// match any case, the old detector re-runs with its own
    /// heuristics, and life continues.
    enum Schema: String {
        /// Initial multi-Ruby detection (PSDK markers + grammar
        /// sniff + RGSS archive extension + Game.ini Library=).
        case initial = "initial"

        /// Adds the bundled `*-rubyXXX.dll` filename signal.
        /// Re-classifies modern PE forks (Pokemon Flux, Vanguard,
        /// Reborn, Inf Fusion) that ship a tiny bootloader
        /// `Scripts.rxdata` + custom archive (`Data_0.fpk`,
        /// etc.) where the grammar sniffer has nothing to read.
        case bundledRubyDLL = "bundled-ruby-dll"
    }

    /// The schema this build's `detect()` implementation
    /// corresponds to. Bump alongside any code change that
    /// re-classifies some games.
    static let currentSchema: Schema = .bundledRubyDLL

    /// Returns the Ruby version raw value (18 / 19 / 30 / 31) for
    /// `gameDirectory`. Mirrors `MKXPRubyVersion`'s enum integer
    /// values from `app_bridge.h`.
    ///
    /// **Decision tree** (first decisive signal wins):
    ///
    ///   1. PSDK markers → **30** (definitive, `.yarb` is
    ///      strictly minor-version-locked).
    ///
    ///   2. Bundled `*-rubyXXX.dll` (`x64-msvcrt-ruby310.dll` etc):
    ///      first digit + second digit of suffix decode to:
    ///        18, 19          → **18** / **19**
    ///        2X (Ruby 2.x)   → **31** (closest available; 2.x is
    ///                                  syntactically Ruby-3-shaped)
    ///        30              → **30**
    ///        31, 32, 33, ...  → **31**
    ///
    ///   3. Script grammar sniff via `RubyScriptGrammarSniffer`:
    ///        - modern Ruby tokens found → **31**
    ///        - only legacy tokens found → use script-file
    ///          extension as prior:
    ///             `.rxdata`  → **18**
    ///             `.rvdata`  → **19**
    ///             `.rvdata2` → **19**
    ///        - inconclusive → fall through to step 3
    ///
    ///   3. Encrypted RGSS archive at project root (Scripts file
    ///      sits inside the archive, so the sniffer couldn't read
    ///      it):
    ///        `.rgssad`  → **18**, `.rgss2a` → **19**, `.rgss3a` → **19**
    ///
    ///   4. `Game.ini` Library= field: `RGSS1xx` → 18, `RGSS2xx`
    ///      / `RGSS3xx` → 19.
    ///
    ///   5. Default → **31** (best guess for modern fork that
    ///      shipped no archive, no Game.ini, and no readable
    ///      Scripts).
    ///
    /// **Why grammar sniff overrides extension**: forks like
    /// Pokemon Reborn 19.5+ keep the `.rxdata` data layout (RGSS1
    /// origin) but rewrote their Scripts in modern Ruby grammar.
    /// The extension is a vestigial pin to the original engine,
    /// not to the script grammar. Reading the actual script source
    /// is the only truth-test.
    ///
    /// User can override the result via
    /// `GameSettings.rubyVersionOverride` if detection misses.
    static func detect(gameDirectory: URL) -> Int {
        let fm = FileManager.default

        // PSDK → 3.0. PSDK pins to Ruby 3.0.x and ships .yarb
        // bytecode that's strictly minor-version-locked. No other
        // value works.
        if isPSDKGame(at: gameDirectory, fm: fm) {
            return 30
        }

        // Bundled modern Ruby DLL. Modern PE forks (Pokemon Flux,
        // Vanguard, Reborn, Infinite Fusion) ship the mkxp-z
        // runtime, which links against `x64-msvcrt-rubyXXX.dll`.
        // The DLL filename's three-digit suffix is the most
        // reliable runtime marker because:
        //
        //   - Game.ini Library= stays at vestigial `RGSS104E.dll`
        //     for these forks (mkxp-z ignores it),
        //   - The compiled `Scripts.rxdata` may be a tiny
        //     bootloader that defers real script load to a custom
        //     archive (`Data_0.fpk`, etc.), so the grammar sniffer
        //     gets only the bootloader's stub and misses the
        //     modern signal,
        //   - The DLL is what the developer linked against on
        //     desktop, so its version is the runtime they tested.
        if let bundledRuby = bundledRubyDLLVersion(at: gameDirectory, fm: fm) {
            return bundledRuby
        }

        // Script grammar sniff. Decodes Scripts.{rxdata,rvdata,
        // rvdata2} (Marshal + Zlib) and looks for tokens that only
        // parse on Ruby 3.x.
        switch RubyScriptGrammarSniffer.sniff(gameDirectory: gameDirectory) {
        case .modern:
            // Definitive: modern grammar can't run on 1.8/1.9.
            return 31

        case .legacy:
            // Successfully read source, no modern tokens. Use the
            // data file extension as the prior to choose 18 vs 19.
            if let scriptVer = rubyVersionFromScriptExtension(
                at: gameDirectory, fm: fm
            ) {
                return scriptVer
            }
            // Scripts file existed (sniffer found one) but
            // extension lookup failed (shouldn't happen). Fall
            // through to archive sniff.
            break

        case .inconclusive:
            // Couldn't read scripts (encrypted archive, missing
            // file, parse error). Continue to archive/INI signals.
            break
        }

        // Encrypted RGSS archive at project root. Scripts live
        // inside the archive; sniffer can't read them without
        // decrypting first. Trust the extension as the engine
        // version.
        //
        // .rgssad → 1.8 (RGSS1 / RPG Maker XP / Ruby 1.8.1)
        // .rgss2a → 1.9 (RGSS2 / RPG Maker VX / Ruby 1.9.2)
        // .rgss3a → 1.9 (RGSS3 / RPG Maker VX Ace / Ruby 1.9.2)
        if let archiveExt = topLevelRgssArchiveExtension(at: gameDirectory, fm: fm) {
            switch archiveExt {
            case "rgssad":  return 18
            case "rgss2a":  return 19
            case "rgss3a":  return 19
            default:        break
            }
        }

        // Game.ini Library= field. RPG Maker stamps the RGSS DLL
        // name into Game.ini; that name encodes the engine version
        // in its three-digit suffix.
        if let libraryRGSS = rgssLibraryMajor(at: gameDirectory, fm: fm) {
            switch libraryRGSS {
            case 1:    return 18
            case 2, 3: return 19
            default:   break
            }
        }

        // Nothing detectable. Best-guess modern: most projects
        // with no readable scripts, no archive, and no Game.ini
        // are loose-script modern forks that shipped only Maps
        // and Items.
        return 31
    }

    /// Returns the Ruby version implied by the `Scripts.*` file
    /// extension found at the project root or under `Data/`.
    /// `.rxdata` → 18, `.rvdata` / `.rvdata2` → 19. nil if no
    /// Scripts file present.
    ///
    /// Used by the grammar sniff path: when `.legacy` is returned
    /// (source readable, no modern tokens), we trust the original
    /// engine extension to pick between 1.8 and 1.9.
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

    /// Scans the top level of `gameDirectory` for a single RGSS
    /// archive file. Returns its extension (lowercased, no dot)
    /// or nil if none found. If multiple archives are present
    /// (some games ship both .rgssad and .rgss2a for compat) the
    /// **highest** version wins, since the engine that opens the
    /// project decides based on Game.ini/Library= which one to
    /// actually load.
    private static func topLevelRgssArchiveExtension(at gameDirectory: URL,
                                                     fm: FileManager) -> String? {
        guard let entries = try? fm.contentsOfDirectory(at: gameDirectory,
                                                        includingPropertiesForKeys: nil) else {
            return nil
        }
        var best: String?
        var bestRank = 0
        for url in entries {
            let ext = url.pathExtension.lowercased()
            let rank: Int
            switch ext {
            case "rgssad":  rank = 1
            case "rgss2a":  rank = 2
            case "rgss3a":  rank = 3
            default:        continue
            }
            if rank > bestRank {
                bestRank = rank
                best = ext
            }
        }
        return best
    }

    /// Reads `Game.ini` and extracts the major version digit from
    /// the `Library=RGSSxxx.dll` entry. Returns 1 / 2 / 3 / nil.
    /// Case-insensitive on the `Library` key per the original
    /// RPG Maker convention.
    private static func rgssLibraryMajor(at gameDirectory: URL,
                                         fm: FileManager) -> Int? {
        let iniURL = gameDirectory.appendingPathComponent("Game.ini")
        guard let data = try? Data(contentsOf: iniURL),
              let text = String(data: data, encoding: .isoLatin1)
                       ?? String(data: data, encoding: .utf8) else {
            return nil
        }
        // Find a line that starts with "Library" (after trimming).
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("library") else { continue }
            // Match RGSS<digit><...>.dll, case-insensitive.
            // The digit immediately after "RGSS" is the major
            // version we care about.
            let upper = line.uppercased()
            guard let range = upper.range(of: "RGSS") else { continue }
            let after = upper[range.upperBound...]
            if let firstDigit = after.first, let major = firstDigit.hexDigitValue {
                return major
            }
        }
        return nil
    }


    /// Scan the game directory for a bundled CRuby DLL whose
    /// filename encodes the Ruby version. Modern mkxp-z-based
    /// forks ship one of:
    ///
    ///   - `x64-msvcrt-rubyXYZ.dll`   (most common, Ruby 2.4+)
    ///   - `msvcrt-rubyXYZ.dll`        (older 32-bit builds)
    ///   - `rubyXYZ.dll`               (some legacy bundles)
    ///
    /// where `XYZ` is `<major><minor>0` for 1.x (e.g. 187 = 1.8.7,
    /// 192 = 1.9.2) or `<major><minor>0` for 2.x/3.x (e.g. 270 =
    /// 2.7, 300 = 3.0, 310 = 3.1).
    ///
    /// Returns nil if no matching file found, otherwise our four
    /// supported buckets:
    ///
    ///   - `18X` / `1.8.X`  → 18
    ///   - `19X` / `1.9.X`  → 19
    ///   - `2XX` / `2.X.Y`  → 31  (Ruby 2.x is syntactically
    ///                              closer to 3.x; map to 31)
    ///   - `30X` / `3.0.X`  → 30
    ///   - `3YX` (Y>=1)     → 31
    private static func bundledRubyDLLVersion(at gameDirectory: URL,
                                              fm: FileManager) -> Int? {
        guard let entries = try? fm.contentsOfDirectory(at: gameDirectory,
                                                        includingPropertiesForKeys: nil) else {
            return nil
        }
        // Match `<anything>ruby<digits>.dll` (case-insensitive),
        // where the digit run is exactly 3 chars (Ruby's stable
        // DLL naming since 1.8.7).
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
                  m.numberOfRanges >= 2 else { continue }
            let digits = nsName.substring(with: m.range(at: 1))
            guard digits.count == 3,
                  let major = Int(String(digits.first!)),
                  let minor = Int(String(digits[digits.index(after: digits.startIndex)])) else {
                continue
            }
            // If the game ships multiple Ruby DLLs (Inf Fusion
            // ships both 300 and 310), the highest version wins,
            // since that's the one mkxp-z's loader picks.
            if major > bestMajor || (major == bestMajor && minor > bestMinor) {
                bestMajor = major
                bestMinor = minor
            }
        }
        guard bestMajor >= 0 else { return nil }
        switch bestMajor {
        case 1:
            return bestMinor <= 8 ? 18 : 19
        case 2:
            // No native Ruby 2.x in our dispatch; 2.x source is
            // generally 3-compatible (no removed methods between
            // 2.7 and 3.0 except minor edges), so 31 is safer
            // than 19 for forks bundling Ruby 2.5/2.6/2.7.
            return 31
        case 3:
            return bestMinor == 0 ? 30 : 31
        default:
            // Future Ruby (4.x) - best effort.
            return 31
        }
    }

    /// Lightweight PSDK detection. Mirrors what the cores branch's
    /// `PSDKDetection` does; duplicated here so this branch's
    /// imports don't depend on cores landing first.
    private static func isPSDKGame(at gameDirectory: URL,
                                   fm: FileManager) -> Bool {
        let candidates = [
            "project.studio",
            "Data/PSDK",
            "Data/Studio",
            "psdk/version.txt",
            "pokemonsdk",
            "psdk",
        ]
        for path in candidates {
            let url = gameDirectory.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }
}
