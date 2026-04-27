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
    static func detect(gameDirectory: URL) -> Int {
        let fm = FileManager.default

        // 1. PSDK → 3.0.
        if isPSDKGame(at: gameDirectory, fm: fm) {
            return 30
        }

        // 2/3. Modern Ruby (JGP modern hint or detected modern syntax).
        //      `detectModernRubyScripts` is the existing implementation
        //      from `GameSettings`; reuse rather than duplicate.
        if GameSettings.detectModernRubyScripts(in: gameDirectory) {
            return 30
        }

        // 4. RGSS archive presence.
        if let items = try? fm.contentsOfDirectory(atPath: gameDirectory.path) {
            let lower = items.map { $0.lowercased() }
            if lower.contains(where: { $0.hasSuffix(".rgssad") })  { return 18 }
            if lower.contains(where: { $0.hasSuffix(".rgss2a") })  { return 19 }
            if lower.contains(where: { $0.hasSuffix(".rgss3a") })  { return 19 }
        }

        // 5. Game.ini's Library= field.
        if let items = try? fm.contentsOfDirectory(atPath: gameDirectory.path) {
            for item in items where item.lowercased().hasSuffix(".ini") {
                let iniURL = gameDirectory.appendingPathComponent(item)
                if let lib = GameEntry.parseINIValue(in: iniURL,
                                                    section: "game",
                                                    key: "library") {
                    let lower = lib.lowercased()
                    if lower.contains("rgss104")            { return 18 }
                    if lower.contains("rgss2") || lower.contains("rgss20") { return 19 }
                    if lower.contains("rgss3")              { return 19 }
                }
            }
        }

        // 6. Unknown → engine default. The dispatcher's UNSET path
        //    falls through to the legacy direct-link 3.1 binding,
        //    so 31 is the right value to return for "I don't know,
        //    use whatever the legacy build did."
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
