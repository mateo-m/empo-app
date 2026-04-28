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
///   2. JGP manifest declaring `runtime: "mkxp-z"` or `useModernRuby`
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

    /// Returns the Ruby version raw value (18 / 19 / 30 / 31) for
    /// `gameDirectory`. Mirrors `MKXPRubyVersion`'s enum integer
    /// values from `app_bridge.h`.
    ///
    /// **Decision tree** (first decisive signal wins):
    ///
    ///   1. PSDK markers → **30** (definitive, `.yarb` is
    ///      strictly minor-version-locked).
    ///
    ///   2. Script grammar sniff via `RubyScriptGrammarSniffer`:
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
        // **XP / RGSS1 → 1.9, not 1.8.** Mirrors JoiPlay's mapping
        // (verified 2026-04-28 by inspecting RPGMPlugin's
        // MainActivity.smali sparse-switch on Game.type). Ruby 1.8
        // ships pre-pthread green-thread implementation in eval.c
        // that uses setjmp/longjmp to manually swap stacks; the
        // code never got ported to arm64 and crashes (SEGV in
        // rb_thread_s_new) the moment any script does Thread.new
        // - which Pokemon Essentials scripts do routinely.
        // Ruby 1.9 has native pthread-backed threading and runs
        // 1.8-grammar XP scripts fine via backwards-compat shims
        // in binding-util.h.
        //
        // mkxp18-merged.o is still shipped for users who flip
        // GameSettings.rubyVersionOverride to 18 manually (matches
        // JoiPlay's `useRuby18` opt-in).
        if let archiveExt = topLevelRgssArchiveExtension(at: gameDirectory, fm: fm) {
            switch archiveExt {
            case "rgssad":  return 19
            case "rgss2a":  return 19
            case "rgss3a":  return 19
            default:        break
            }
        }

        // Game.ini Library= field. RPG Maker stamps the RGSS DLL
        // name into Game.ini; that name encodes the engine version
        // in its three-digit suffix. RGSS1 (XP) → 1.9 here for the
        // same reason as the archive sniff above.
        if let libraryRGSS = rgssLibraryMajor(at: gameDirectory, fm: fm) {
            switch libraryRGSS {
            case 1:    return 19
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
    /// extension found at the project root or under `Data/`. All
    /// pre-3.x extensions map to **1.9**, matching JoiPlay's
    /// mapping. Ruby 1.8's broken arm64 threading makes it
    /// unsuitable as a default; users can opt in via
    /// GameSettings.rubyVersionOverride. nil if no Scripts file
    /// present.
    ///
    /// Used by the grammar sniff path: when `.legacy` is returned
    /// (source readable, no modern tokens), we use this to confirm
    /// it's pre-3.x grammar.
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
                return 19
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
