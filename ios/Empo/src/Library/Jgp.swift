import Foundation
import GameProbe
import UIKit

/// JoiPlay archive runtime type. Any value outside the first-class
/// cases is surfaced as `.unsupported(raw:)` so we can display a
/// precise error. The supported set covers every RGSS version our
/// mkxp-z engine handles (XP = RGSS1, VX = RGSS2, VX Ace = RGSS3).
/// It also covers the explicit "mkxp-z" label JoiPlay uses for
/// games pre-packaged against the mkxp-z engine with Ruby 3. That
/// label matches our runtime exactly, so we accept it too.
/// JoiPlay also issues archives for Ren'Py, TyranoBuilder, HTML,
/// Flash, and MZ/MV. We have no runtime for those and reject them
/// with a per-type explanation during import.
enum JgpRuntime: Codable, Equatable {
    case rpgmxp  // RPG Maker XP  (RGSS1)
    case rpgmvx  // RPG Maker VX  (RGSS2)
    case rpgmvxace  // RPG Maker VX Ace (RGSS3)
    case mkxpZ  // Prebuilt for mkxp-z with Ruby 3
    case unsupported(raw: String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "rpgmxp": self = .rpgmxp
        case "rpgmvx": self = .rpgmvx
        case "rpgmvxace": self = .rpgmvxace
        case "mkxp-z": self = .mkxpZ
        default: self = .unsupported(raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .rpgmxp: try c.encode("rpgmxp")
        case .rpgmvx: try c.encode("rpgmvx")
        case .rpgmvxace: try c.encode("rpgmvxace")
        case .mkxpZ: try c.encode("mkxp-z")
        case .unsupported(let r): try c.encode(r)
        }
    }

    var displayName: String {
        switch self {
        case .rpgmxp: "RPG Maker XP"
        case .rpgmvx: "RPG Maker VX"
        case .rpgmvxace: "RPG Maker VX Ace"
        case .mkxpZ: "mkxp-z"
        case .unsupported(let r): r
        }
    }
}

/// `manifest.json`: identifies the game and its runtime.
struct JgpManifest: Codable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let icon: String?
    let executable: String?
    let type: JgpRuntime
}

/// `configuration.json`: engine and renderer preferences bundled by the
/// game developer. All fields are optional. We ignore anything
/// unsupported on our platform.
struct JgpConfiguration: Codable {
    // Shared
    let cheats: Bool?

    // RPG Maker subset
    let windowSize: String?  // "640x480"
    let fontScale: String?  // stored as string in JGP; parsed to Double
    let speedUp: String?  // "1", "2", "3" ...
    let smoothScaling: Bool?
    let vsync: Bool?
    let frameSkip: Bool?
    let solidFonts: Bool?
    let pathCache: Bool?
    let enablePostloadScripts: Bool?
    let customFont: String?
}

enum Jgp {
    /// Entry-point bundle of parsed JGP files.
    struct Bundle {
        let manifest: JgpManifest
        let configuration: JgpConfiguration?
        let iconData: Data?
        /// Directory containing the game itself (after removing JGP-specific files).
        let gameRoot: URL
    }

    /// Parse the JGP JSON files out of an already-extracted JGP directory
    /// and resolve the icon data. Returns nil if manifest.json is missing or
    /// unreadable. Other files are optional.
    ///
    /// Callers are responsible for removing the JGP-specific files
    /// (manifest.json, configuration.json, icon) from the final game directory
    /// after import. `gamepad.json` stays in the game tree and is translated
    /// at load time by `JoiPlayControlsTranslator`.
    static func parseBundle(at root: URL) -> Bundle? {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let manifestRaw = try? String(contentsOf: manifestURL, encoding: .utf8),
            let manifest = decodeWithComments(JgpManifest.self, from: manifestRaw)
        else {
            return nil
        }

        let configuration: JgpConfiguration? = {
            let url = root.appendingPathComponent("configuration.json")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return decodeWithComments(JgpConfiguration.self, from: raw)
        }()

        let iconData: Data? = {
            guard let iconPath = manifest.icon, !iconPath.isEmpty else { return nil }
            let iconURL = root.appendingPathComponent(iconPath)
            return try? Data(contentsOf: iconURL)
        }()

        return Bundle(
            manifest: manifest,
            configuration: configuration,
            iconData: iconData,
            gameRoot: root
        )
    }

    /// JGP uses the same `//` comment tolerance as mkxp.json. Strip comments
    /// before handing to `JSONDecoder`.
    private static func decodeWithComments<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        JSON5LiteParser.decode(T.self, from: raw)
    }
}

// MARK: - Configuration -> GameSettings mapping

extension JgpConfiguration {
    /// Engine keys that belong in `EmpoState/mkxp.json`.
    func toMkxpEngineValues() -> MkxpEngineValues {
        MkxpEngineValues(
            smoothScaling: smoothScaling,
            frameSkip: frameSkip,
            vsync: vsync,
            pathCache: pathCache,
            fontScale: fontScale.flatMap(Double.init),
            solidFonts: solidFonts
        )
    }

    /// Translate a JGP `configuration.json` into our per-game `GameSettings`.
    /// Anything unsupported on iOS is ignored (`renpy_*`, `useRuby18`, etc.).
    /// Engine keys route through `toMkxpEngineValues()` into mkxp.json.
    func toGameSettings() -> GameSettings {
        var s = GameSettings()
        // Intentionally NOT mapping `enablePostloadScripts` onto our
        // `postloadScripts` setting. JoiPlay's flag controls its own
        // JoiPlay-specific postload hooks. Ours controls the engine's
        // compat-shim pipeline (NilClass safe-stubs, $joiplay signal,
        // MKXP.plugin_version, Graphics.poke_* aliases, Pokemon-
        // specific session-reset hooks, etc.). JGPs that set
        // `enablePostloadScripts: false` (notably Reborn) still
        // depend on our compat shims to boot, so leave our postload
        // path enabled by default.

        if let speedStr = speedUp, let speed = Int(speedStr), speed > 1 {
            s.speedMultiplier = speed
        }
        // The legacy `windowSize` JGP field encodes a target SDL
        // window size (e.g. "1920x1080"). On iOS the window is
        // always fullscreen, so this value can't be honored as
        // dimensions. The host also doesn't expose an aspect-ratio
        // override (RGSS games hardcode their layout to the
        // developer-chosen `scRes`, so feeding an arbitrary buffer
        // size would just clip / leave gutters in the rendered
        // scene). We skip JGP `windowSize` entirely. The
        // user-facing Render scale picker is the supported way to
        // raise pixel density.
        _ = windowSize
        return s
    }
}
