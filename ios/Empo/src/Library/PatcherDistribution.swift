import Foundation

/// Bundled "Patches/" distribution pipeline for the engine's
/// `Patcher` (see `mkxp-z-apple-mobile/src/patcher.{h,cpp}`).
///
/// At every game launch:
///   1. Resolve a *canonical Empo id* for the game from its
///      `GameMetadata.manifestId` (JGP imports) or `Game.ini` Title
///      field (raw zip / 7z / rar / folder imports).
///   2. Concatenate `Patches/_global/patches.json` (always-applied
///      toolkit-wide rules) with `Patches/<canonical-id>/patches.json`
///      (per-game rules) into a single JSON file written to the game
///      folder as `patches.json`.
///   3. The engine's `Patcher` constructor auto-discovers
///      `patches.json` in cwd (the game folder) and applies the rules
///      to every script section before Ruby evaluates it.
///
/// User customization (Phase 2): users will be able to drop a
/// `user-patches.json` alongside this file; the engine will honor
/// both. For Phase 1 the canonical `patches.json` is fully managed
/// by Empo and any manual edits get overwritten on the next launch.
///
/// Schema: see `ios/Empo/curated-patches/gameRegistry.json` and the
/// per-game `patches.json` files for examples.
enum PatcherDistribution {

    private static let registryFilename = "gameRegistry.json"
    private static let patchesFilename = "patches.json"
    private static let globalDirName = "_global"
    private static let bundleSubdir = "Patches"

    // MARK: - Entry point

    /// Resolve canonical id, merge applicable patches, write
    /// `patches.json` to the per-game state directory. No-op (and
    /// clears any stale generated file) if no patches apply.
    ///
    /// `stateDirectory` is `Documents/EmpoState/<id>/` (where the
    /// generated `patches.json` is written and where the engine's
    /// Patcher auto-discovery looks for it).
    /// `gameDirectory` is `Documents/Games/<id>/` (the imported
    /// game folder, source of `Game.ini` for title-based canonical
    /// id resolution).
    static func applyToGame(at stateDirectory: URL,
                            gameDirectory: URL,
                            gameId: String) {
        let outURL = stateDirectory.appendingPathComponent(patchesFilename)

        let canonicalId = resolveCanonicalId(gameDirectory: gameDirectory, gameId: gameId)

        // Read all applicable patch sources. Order matters: global
        // first so per-game rules can override (last-writer-wins
        // semantics inside the engine's Patcher::apply loop, which
        // applies rules sequentially).
        var rules: [[String: Any]] = []

        if let global = readPatchRules(canonicalId: globalDirName) {
            rules.append(contentsOf: global)
        }

        if let cid = canonicalId,
           let perGame = readPatchRules(canonicalId: cid) {
            rules.append(contentsOf: perGame)
        }

        if rules.isEmpty {
            // Nothing to write. Clean up any stale file from a
            // previous launch (e.g., the game's canonical id
            // changed between releases, or we removed all rules).
            try? FileManager.default.removeItem(at: outURL)
            return
        }

        let payload: [String: Any] = ["rpgm": rules]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: outURL, options: .atomic)
        }
    }

    // MARK: - Canonical-id resolution

    /// Walk the gameRegistry matchers in order:
    ///   manifestId (cheapest) -> iniTitle -> fingerprint (lazy)
    /// First matching game wins.
    private static func resolveCanonicalId(gameDirectory: URL, gameId: String) -> String? {
        guard let registry = loadRegistry() else {
            NSLog("[patcher-dist] registry load failed")
            return nil
        }

        // 1. JGP manifest id (only games imported via .jgp have one).
        let metadata = GameMetadata.load(for: gameId)
        if let mid = metadata.manifestId, !mid.isEmpty {
            for game in registry.games {
                for matcher in game.matchers where matcher.type == "manifestId" {
                    if matcher.value == mid {
                        NSLog("[patcher-dist] %@ -> %@ (manifestId)", gameId, game.id)
                        return game.id
                    }
                }
            }
        }

        // 2. Game.ini Title (case-insensitive substring) - works for
        //    every import path including raw zip/rar/folder.
        if let title = readIniTitle(gameDirectory: gameDirectory) {
            let normalized = title.lowercased()
            for game in registry.games {
                for matcher in game.matchers where matcher.type == "iniTitle" {
                    if normalized.contains(matcher.value.lowercased()) {
                        NSLog("[patcher-dist] %@ -> %@ (iniTitle: %@)",
                              gameId, game.id, title)
                        return game.id
                    }
                }
            }
        }

        // 3. Fingerprint matchers go here (Phase 1.5: only when we hit
        //    a game whose Title collides with another). Skipped for
        //    now to keep import latency low.

        NSLog("[patcher-dist] %@ -> unresolved (no matcher fired)", gameId)
        return nil
    }

    // MARK: - Registry loading

    private struct Matcher: Decodable {
        let type: String
        let value: String
    }

    private struct Game: Decodable {
        let id: String
        let name: String
        let matchers: [Matcher]
    }

    private struct Registry: Decodable {
        let games: [Game]
    }

    private static func loadRegistry() -> Registry? {
        guard let url = bundleURL(forSubpath: registryFilename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // gameRegistry.json uses JSON5 features (line comments only).
        // Strip `//` line comments before handing to Foundation's
        // strict JSONDecoder. Keeps the registry readable for
        // curators without pulling in a JSON5 library on the
        // Empo side - the engine still parses the per-game JSONs
        // via json5pp.
        let cleaned = stripLineComments(in: data) ?? data
        return try? JSONDecoder().decode(Registry.self, from: cleaned)
    }

    // MARK: - Patch rule loading

    /// Read the `rpgm` array from `Patches/<id>/patches.json` in the
    /// app bundle. Returns nil if the file doesn't exist; returns []
    /// for a present-but-empty file (which gets merged as nothing).
    private static func readPatchRules(canonicalId: String) -> [[String: Any]]? {
        let path = "\(canonicalId)/\(patchesFilename)"
        guard let url = bundleURL(forSubpath: path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let cleaned = stripLineComments(in: data) ?? data
        guard let json = try? JSONSerialization.jsonObject(with: cleaned),
              let obj = json as? [String: Any],
              let rpgm = obj["rpgm"] as? [[String: Any]] else {
            return nil
        }
        return rpgm
    }

    // MARK: - Helpers

    private static func bundleURL(forSubpath path: String) -> URL? {
        // Assets.bundle is registered in project.yml; the curated
        // patches mirror its layout under "Patches/".
        guard let assetsBundleURL = Bundle.main.url(
            forResource: "Assets", withExtension: "bundle"
        ) else {
            NSLog("[patcher-dist] Bundle.main has no Assets.bundle resource")
            return nil
        }
        let result = assetsBundleURL
            .appendingPathComponent(bundleSubdir)
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: result.path) else {
            return nil
        }
        return result
    }

    /// Parse `[Game]\nTitle=...` from the game's `Game.ini`.
    /// Returns nil if the file is missing or has no Title.
    private static func readIniTitle(gameDirectory: URL) -> String? {
        let iniURL = gameDirectory.appendingPathComponent("Game.ini")
        // Game.ini is typically Windows-1252 / Latin-1; fall back
        // to UTF-8 then ISO Latin 1 if the first decode fails.
        guard let data = try? Data(contentsOf: iniURL) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        // Swift treats `\r\n` as a single grapheme cluster, so a
        // closure-based `split(whereSeparator:)` checking against
        // "\n" or "\r" returns the whole CRLF-terminated text as a
        // single "line". Use `components(separatedBy:)` with
        // `CharacterSet.newlines` instead - it covers \r, \n, \r\n,
        // \u2028 (line separator), \u2029 (paragraph separator),
        // and treats any of those as a line break. This is the
        // standard Foundation idiom for "split a textual file by
        // line endings of any kind".
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("title=") {
                return String(line.dropFirst("title=".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Strip JSON5-style `//` line comments so Foundation's strict
    /// JSON decoder accepts the file. NOT a full JSON5 parser - we
    /// don't handle block comments, trailing commas, single quotes,
    /// or strings containing `//` followed by `\n`. Curators should
    /// keep `//` comments out of string values; if that ever
    /// becomes a constraint, swap in a real JSON5 library.
    private static func stripLineComments(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = ""
        out.reserveCapacity(text.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Naive: drop everything from the first `//` to end-of-line.
            // Doesn't handle `//` inside string literals; acceptable
            // because we control the curated content.
            if let r = line.range(of: "//") {
                out.append(contentsOf: line[..<r.lowerBound])
            } else {
                out.append(contentsOf: line)
            }
            out.append("\n")
        }
        return out.data(using: .utf8)
    }
}
