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
    /// **Conservative-by-default policy:** only tag a game with
    /// 3.0 / 1.9 / 1.8 when the dispatch target's binding code
    /// actually exists and has been verified to work for that game
    /// class. Everything else lands on the legacy 3.1 +
    /// syntax-transform path, which is the proven-good code path
    /// today.
    ///
    /// 1.8 / 1.9 native binding compiles don't exist yet (see
    /// MULTI_RUBY_PLAN.md — the per-version binding-mri.cpp compile
    /// against vintage Ruby C APIs is substantial work that hasn't
    /// landed on this branch). The dispatcher falls through to
    /// legacy for those values, so even if we tagged a game as 1.8,
    /// it'd actually run on 3.1+syntax-transform — fine, but the
    /// log line would be misleading. Better to tag honestly.
    ///
    /// Modern PE (Reborn 19.5+, PE v20+) games HAVE been running
    /// on 3.1+syntax-transform with `useModernRuby=true` flipping
    /// off the LEGACY parser path. Tagging them as 30 would route
    /// to mkxp30-merged.o which has NO syntax-transform — risky if
    /// the game has any legacy-grammar fragments left. Keep them
    /// on 31 for now.
    static func detect(gameDirectory: URL) -> Int {
        let fm = FileManager.default

        // PSDK → 3.0. PSDK pins to Ruby 3.0.x and ships .yarb
        // bytecode that's strictly minor-version-locked. No other
        // value works.
        if isPSDKGame(at: gameDirectory, fm: fm) {
            return 30
        }

        // RGSS archive type. Authoritative when present: the file
        // extension encodes which RGSS engine was used to pack the
        // game, which in turn pins the Ruby version.
        //
        //   .rgssad  → RGSS1 / RPG Maker XP   → Ruby 1.8.1
        //   .rgss2a  → RGSS2 / RPG Maker VX   → Ruby 1.9.2
        //   .rgss3a  → RGSS3 / RPG Maker VX Ace → Ruby 1.9.2
        //
        // We sniff the directory's top level; we don't recurse,
        // because the archive sits next to Game.ini at the project
        // root. Loose-script projects (no archive) fall through to
        // the next heuristic.
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
        // in its three-digit suffix. Ranges:
        //   RGSS1xx → RGSS1 → 1.8
        //   RGSS2xx → RGSS2 → 1.9
        //   RGSS3xx → RGSS3 → 1.9
        // Loose-script Reborn / PE forks frequently strip Game.ini
        // entirely, so this only fires for vanilla-layout projects
        // that didn't get caught by the archive sniff above.
        if let libraryRGSS = rgssLibraryMajor(at: gameDirectory, fm: fm) {
            switch libraryRGSS {
            case 1: return 18
            case 2, 3: return 19
            default: break
            }
        }

        // Default: 3.1 (legacy direct-link path with
        // syntax-transform). Includes anything that didn't match
        // PSDK / RGSS archive / Game.ini — typically loose-script
        // modern PE forks (Reborn 19.5+, PE v20+) running on
        // mkxp-z's modernised binding.
        return 31
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
