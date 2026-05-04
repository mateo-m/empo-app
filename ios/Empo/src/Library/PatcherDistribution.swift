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
///      (per-game rules) into a single JSON file written to
///      `<container>/EmpoState/patches.json`.
///   3. The engine's `Patcher` constructor reads `patches.json`
///      from the managed config dir (`<container>/EmpoState/`) and
///      applies the rules to every script section before Ruby
///      evaluates it.
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
    /// `patches.json` into `<container>/EmpoState/`. No-op (and
    /// clears any stale generated file) if no patches apply.
    static func applyToGame(container: GameContainer) {
        let outURL = container.patchesURL

        let canonicalId = resolveCanonicalId(container: container)

        // Read all applicable patch sources. Order matters: global
        // first so per-game rules can override (last-writer-wins
        // semantics inside the engine's Patcher::apply loop, which
        // applies rules sequentially).
        var rules: [[String: Any]] = []

        if let global = readPatchRules(canonicalId: globalDirName) {
            rules.append(contentsOf: global)
        }

        if let cid = canonicalId,
            let perGame = readPatchRules(canonicalId: cid)
        {
            rules.append(contentsOf: perGame)
        }

        if rules.isEmpty {
            // Nothing to write. Clean up any stale file from a
            // previous launch (e.g., the game's canonical id
            // changed between releases, or we removed all rules).
            try? FileManager.default.removeItem(at: outURL)
            return
        }

        container.ensureEmpoStateDirectory()
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
    private static func resolveCanonicalId(container: GameContainer) -> String? {
        guard let registry = loadRegistry() else {
            NSLog("[patcher-dist] registry load failed")
            return nil
        }

        let gameId = container.id

        // 1. JGP manifest id (only games imported via .jgp have one).
        let metadata = GameMetadata.load(from: container)
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
        if let title = readIniTitle(gameURL: container.gameURL) {
            let normalized = title.lowercased()
            for game in registry.games {
                for matcher in game.matchers where matcher.type == "iniTitle" {
                    if normalized.contains(matcher.value.lowercased()) {
                        NSLog(
                            "[patcher-dist] %@ -> %@ (iniTitle: %@)",
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
            let rpgm = obj["rpgm"] as? [[String: Any]]
        else {
            return nil
        }
        return rpgm
    }

    // MARK: - Helpers

    private static func bundleURL(forSubpath path: String) -> URL? {
        // Assets.bundle is registered in project.yml; the curated
        // patches mirror its layout under "Patches/".
        guard
            let assetsBundleURL = Bundle.main.url(
                forResource: "Assets", withExtension: "bundle"
            )
        else {
            NSLog("[patcher-dist] Bundle.main has no Assets.bundle resource")
            return nil
        }
        let result =
            assetsBundleURL
            .appendingPathComponent(bundleSubdir)
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: result.path) else {
            return nil
        }
        return result
    }

    /// Parse `[Game]\nTitle=...` from the game's `Game.ini`.
    /// Returns nil if the file is missing or has no Title.
    private static func readIniTitle(gameURL: URL) -> String? {
        let iniURL = gameURL.appendingPathComponent("Game.ini")
        return GameEntry.parseINIValue(in: iniURL, section: "game", key: "title")
    }

    private static func stripLineComments(in data: Data) -> Data? {
        JSON5LiteParser.stripLineComments(in: data)
    }
}
