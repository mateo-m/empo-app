import Foundation

/// Which RPG Maker web engine a game targets. MV and MZ games are
/// HTML5/JavaScript applications; Empo has no runtime for them yet,
/// so the import pipeline uses this detection to reject them with a
/// specific message instead of the generic "not an RPG Maker game"
/// error.
public enum RmWebGameKind: String, Codable, Equatable, Sendable {
    case mv
    case mz
}

/// Detects RPG Maker MV/MZ game layouts.
///
/// Layouts in the wild:
///  - Desktop MV export:  `<root>/www/index.html` + `www/js/rpg_core.js`
///    (the root also has the NW.js `Game.exe`, `package.json`, dlls…)
///  - Browser/mobile MV:  `<root>/index.html` + `js/rpg_core.js`
///  - MZ (all exports):   `<root>/index.html` + `js/rmmz_core.js`
///    (the `www/` variant is checked for MZ too, for consistency)
///
/// Detection requires the engine core file, not just index.html, so
/// random web pages are not claimed. MZ wins when both core files
/// are present.
public enum RmWebDetection {

    public static func detect(
        in gameDirectory: URL,
        fileManager: FileManager = .default
    ) -> RmWebGameKind? {
        for component in ["", "www"] {
            let webRoot =
                component.isEmpty
                ? gameDirectory
                : gameDirectory.appendingPathComponent(component, isDirectory: true)
            guard fileExists(webRoot.appendingPathComponent("index.html"), fileManager)
            else {
                continue
            }
            let js = webRoot.appendingPathComponent("js", isDirectory: true)
            if fileExists(js.appendingPathComponent("rmmz_core.js"), fileManager) {
                return .mz
            }
            if fileExists(js.appendingPathComponent("rpg_core.js"), fileManager) {
                return .mv
            }
        }
        return nil
    }

    private static func fileExists(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
