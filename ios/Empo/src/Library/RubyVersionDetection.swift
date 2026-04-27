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

        // Default: 3.1 (legacy direct-link path). Includes:
        //   - vintage RGSS1/RGSS2/RGSS3 games (1.8/1.9 grammar)
        //   - modern mkxp-z JGPs (Reborn 19.5+, PE v20+)
        //   - anything we don't have a confirmed-working native
        //     binding for.
        //
        // Once 1.8/1.9 native builds land + per-version binding
        // compiles work, extend this to dispatch by RGSS archive
        // type + Library= field (see git history of this file for
        // the eager-detection variant).
        return 31
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
