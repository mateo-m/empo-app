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
///
/// All name matching is case-insensitive (`Index.HTML`,
/// `WWW/js/RPG_Core.js`, ...): games are authored on
/// case-insensitive Windows/macOS filesystems, and the archive
/// probe's marker matching (`GameImportValidator`'s
/// `isRmWebMarker`) already case-folds, so on-disk detection must
/// agree or mixed-case archives extract markers yet never detect.
/// Each directory is listed once and its names case-folded - the
/// same approach as rmweb-core's `CaseInsensitivePathResolver`, in
/// miniature.
public enum RmWebDetection {

    public static func detect(
        in gameDirectory: URL,
        fileManager: FileManager = .default
    ) -> RmWebGameKind? {
        // Candidate web roots: the game directory itself, then a
        // `www/` wrapper (desktop NW.js exports), both matched
        // case-insensitively.
        let rootListing = caseFoldedListing(of: gameDirectory, fileManager)
        var webRoots: [(URL, [String: String])] = [(gameDirectory, rootListing)]
        if let www = rootListing["www"] {
            let wwwURL = gameDirectory.appendingPathComponent(www, isDirectory: true)
            // A non-directory `www` yields an empty listing below
            // and the candidate simply never matches.
            webRoots.append((wwwURL, caseFoldedListing(of: wwwURL, fileManager)))
        }

        for (webRoot, listing) in webRoots {
            // A directory literally named index.html doesn't count.
            guard let indexName = listing["index.html"],
                isFile(webRoot.appendingPathComponent(indexName), fileManager)
            else {
                continue
            }
            guard let jsName = listing["js"] else { continue }
            let js = webRoot.appendingPathComponent(jsName, isDirectory: true)
            let jsListing = caseFoldedListing(of: js, fileManager)
            if let core = jsListing["rmmz_core.js"],
                isFile(js.appendingPathComponent(core), fileManager)
            {
                return .mz
            }
            if let core = jsListing["rpg_core.js"],
                isFile(js.appendingPathComponent(core), fileManager)
            {
                return .mv
            }
        }
        return nil
    }

    /// One directory listing, case-folded: lowercased name ->
    /// actual on-disk name. First writer wins on case-fold
    /// collisions (matching `CaseInsensitivePathResolver`); a
    /// missing or non-directory URL yields an empty map.
    private static func caseFoldedListing(
        of directory: URL, _ fm: FileManager
    ) -> [String: String] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return [:]
        }
        var map: [String: String] = [:]
        for name in names {
            let folded = name.lowercased()
            if map[folded] == nil { map[folded] = name }
        }
        return map
    }

    private static func isFile(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
