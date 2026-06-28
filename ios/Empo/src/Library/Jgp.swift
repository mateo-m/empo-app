import Foundation
import GameProbe
import UIKit

/// JoiPlay archive runtime type. Any value outside the first-class
/// cases is surfaced as `.unsupported(raw:)` so we can display a
/// precise error. The supported set covers every RGSS version our
/// mkxp-z engine handles (XP = RGSS1, VX = RGSS2, VX Ace = RGSS3)
/// plus the explicit "mkxp-z" label JoiPlay uses for games that
/// were pre-packaged against the mkxp-z engine with Ruby 3 - that
/// label matches our runtime exactly so we accept it too.
/// JoiPlay also issues archives for Ren'Py, TyranoBuilder, HTML,
/// Flash, and MZ/MV - we have no runtime for those and reject them
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

/// `manifest.json` - identifies the game and its runtime.
struct JgpManifest: Codable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let icon: String?
    let executable: String?
    let type: JgpRuntime
}

/// `configuration.json` - engine and renderer preferences bundled by the
/// game developer. All fields are optional; anything unsupported on our
/// platform is ignored.
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

/// `gamepad.json` - touch control layout hints. Values are Android key codes.
struct JgpGamepad: Codable {
    let btnOpacity: Int?
    let btnScale: Int?
    let aKeyCode: Int?
    let bKeyCode: Int?
    let cKeyCode: Int?
    let xKeyCode: Int?
    let yKeyCode: Int?
    let zKeyCode: Int?
    let lKeyCode: Int?
    let rKeyCode: Int?
}

enum Jgp {
    /// Entry-point bundle of parsed JGP files.
    struct Bundle {
        let manifest: JgpManifest
        let configuration: JgpConfiguration?
        let gamepad: JgpGamepad?
        let iconData: Data?
        /// Directory containing the game itself (after removing JGP-specific files).
        let gameRoot: URL
    }

    /// Parse the three JSON files out of an already-extracted JGP directory
    /// and resolve the icon data. Returns nil if manifest.json is missing or
    /// unreadable. Other files are optional.
    ///
    /// Callers are responsible for removing the JGP-specific files
    /// (manifest.json, configuration.json, gamepad.json, icon) from the
    /// final game directory after import if they don't want them shipped
    /// alongside the engine files.
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

        let gamepad: JgpGamepad? = {
            let url = root.appendingPathComponent("gamepad.json")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return decodeWithComments(JgpGamepad.self, from: raw)
        }()

        let iconData: Data? = {
            guard let iconPath = manifest.icon, !iconPath.isEmpty else { return nil }
            let iconURL = root.appendingPathComponent(iconPath)
            return try? Data(contentsOf: iconURL)
        }()

        return Bundle(
            manifest: manifest,
            configuration: configuration,
            gamepad: gamepad,
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
    /// Translate a JGP `configuration.json` into our per-game `GameSettings`.
    /// Anything unsupported on iOS is ignored (`renpy_*`, `useRuby18`, etc.).
    func toGameSettings() -> GameSettings {
        var s = GameSettings()
        s.smoothScaling = smoothScaling
        s.vsync = vsync
        s.frameSkip = frameSkip
        s.solidFonts = solidFonts
        s.pathCache = pathCache
        // Intentionally NOT mapping `enablePostloadScripts` onto our
        // `postloadScripts` setting. JoiPlay's flag controls its own
        // JoiPlay-specific postload hooks; ours controls the engine's
        // compat-shim pipeline (NilClass safe-stubs, $joiplay signal,
        // MKXP.plugin_version, Graphics.poke_* aliases, Pokemon-
        // specific session-reset hooks, etc.). JGPs that set
        // `enablePostloadScripts: false` (notably Reborn) still
        // depend on our compat shims to boot, so leave our postload
        // path enabled by default.

        if let scaleStr = fontScale, let scale = Double(scaleStr) {
            s.fontScale = scale
        }
        if let speedStr = speedUp, let speed = Int(speedStr), speed > 1 {
            s.speedMultiplier = speed
        }
        // The legacy `windowSize` JGP field encodes a target SDL
        // window size (e.g. "1920x1080"). On iOS the window is
        // always fullscreen, so this value can't be honored as
        // dimensions; and the host doesn't expose an aspect-ratio
        // override (RGSS games hardcode their layout to the
        // developer-chosen `scRes`, so feeding an arbitrary buffer
        // size would just clip / leave gutters in the rendered
        // scene). We skip JGP `windowSize` entirely - the
        // user-facing Render scale picker is the supported way to
        // bump pixel density.
        _ = windowSize
        return s
    }
}

// MARK: - Gamepad mapping

extension JgpGamepad {
    /// Installed-layout shape the import pipeline hands to
    /// `ControlsLayout.writeInitialPerGameLayout`. We don't touch
    /// the private `PersistedLayout` type here - the pipeline
    /// expands this into a persisted snapshot for the game.
    struct SeedLayout {
        let dpadCenter: CGPoint
        let dpadSize: CGFloat
        let buttons: [ButtonModel]
    }

    /// Map the JGP Android key codes to an initial touch-control
    /// layout snapshot. Unknown key codes fall back to the RGSS
    /// default for that slot so the game is always playable even
    /// with an incomplete JGP gamepad.json.
    func toSeedLayout() -> SeedLayout {
        struct Slot {
            let key: Int?
            let defaultScancode: Int32
            let label: String
            let relativeCenter: CGPoint
            let size: CGFloat
        }

        let slots: [Slot] = [
            Slot(
                key: aKeyCode, defaultScancode: Int32(MKXP_SCANCODE_RETURN),
                label: "A", relativeCenter: CGPoint(x: 0.85, y: 0.78), size: 60),
            Slot(
                key: bKeyCode, defaultScancode: Int32(MKXP_SCANCODE_ESCAPE),
                label: "B", relativeCenter: CGPoint(x: 0.72, y: 0.70), size: 56),
            Slot(
                key: xKeyCode, defaultScancode: Int32(MKXP_SCANCODE_LSHIFT),
                label: "X", relativeCenter: CGPoint(x: 0.62, y: 0.82), size: 50),
            Slot(
                key: yKeyCode, defaultScancode: Int32(MKXP_SCANCODE_LCTRL),
                label: "Y", relativeCenter: CGPoint(x: 0.72, y: 0.62), size: 44),
        ]

        let buttons = slots.map { slot -> ButtonModel in
            let scancode = slot.key.flatMap(androidKeyCodeToScancode) ?? slot.defaultScancode
            return ButtonModel(
                label: slot.label,
                scancode: scancode,
                relativeCenter: slot.relativeCenter,
                size: slot.size
            )
        }

        return SeedLayout(
            dpadCenter: ControlsLayout.defaultDPadCenter,
            dpadSize: ControlsLayout.defaultDPadSize,
            buttons: buttons
        )
    }

    /// Android `KeyEvent` constant -> mkxp scancode. Returns nil for key
    /// codes we don't have an equivalent for.
    /// See: https://developer.android.com/reference/android/view/KeyEvent
    private func androidKeyCodeToScancode(_ code: Int) -> Int32? {
        switch code {
        // Letters (Android KEYCODE_A=29 ... KEYCODE_Z=54)
        case 29: return Int32(MKXP_SCANCODE_A)
        case 30: return Int32(MKXP_SCANCODE_B)
        case 31: return Int32(MKXP_SCANCODE_C)
        case 32: return Int32(MKXP_SCANCODE_D)
        case 33: return Int32(MKXP_SCANCODE_E)
        case 34: return Int32(MKXP_SCANCODE_F)
        case 35: return Int32(MKXP_SCANCODE_G)
        case 36: return Int32(MKXP_SCANCODE_H)
        case 37: return Int32(MKXP_SCANCODE_I)
        case 38: return Int32(MKXP_SCANCODE_J)
        case 39: return Int32(MKXP_SCANCODE_K)
        case 40: return Int32(MKXP_SCANCODE_L)
        case 41: return Int32(MKXP_SCANCODE_M)
        case 42: return Int32(MKXP_SCANCODE_N)
        case 43: return Int32(MKXP_SCANCODE_O)
        case 44: return Int32(MKXP_SCANCODE_P)
        case 45: return Int32(MKXP_SCANCODE_Q)
        case 46: return Int32(MKXP_SCANCODE_R)
        case 47: return Int32(MKXP_SCANCODE_S)
        case 48: return Int32(MKXP_SCANCODE_T)
        case 49: return Int32(MKXP_SCANCODE_U)
        case 50: return Int32(MKXP_SCANCODE_V)
        case 51: return Int32(MKXP_SCANCODE_W)
        case 52: return Int32(MKXP_SCANCODE_X)
        case 53: return Int32(MKXP_SCANCODE_Y)
        case 54: return Int32(MKXP_SCANCODE_Z)

        // Arrows (KEYCODE_DPAD_*)
        case 19: return Int32(MKXP_SCANCODE_UP)
        case 20: return Int32(MKXP_SCANCODE_DOWN)
        case 21: return Int32(MKXP_SCANCODE_LEFT)
        case 22: return Int32(MKXP_SCANCODE_RIGHT)

        // Common controls. mkxp-ios only models left-variants of modifiers.
        case 59, 60: return Int32(MKXP_SCANCODE_LSHIFT)  // SHIFT_LEFT/RIGHT
        case 66: return Int32(MKXP_SCANCODE_RETURN)  // ENTER
        case 111: return Int32(MKXP_SCANCODE_ESCAPE)  // ESCAPE
        case 62: return Int32(MKXP_SCANCODE_SPACE)  // SPACE
        case 113, 114: return Int32(MKXP_SCANCODE_LCTRL)  // CTRL_LEFT/RIGHT
        case 57, 58: return Int32(MKXP_SCANCODE_LALT)  // ALT_LEFT/RIGHT
        case 61: return Int32(MKXP_SCANCODE_TAB)
        case 67: return Int32(MKXP_SCANCODE_BACKSPACE)

        // Digits 0-9 (top row)
        case 7: return Int32(MKXP_SCANCODE_0)
        case 8: return Int32(MKXP_SCANCODE_1)
        case 9: return Int32(MKXP_SCANCODE_2)
        case 10: return Int32(MKXP_SCANCODE_3)
        case 11: return Int32(MKXP_SCANCODE_4)
        case 12: return Int32(MKXP_SCANCODE_5)
        case 13: return Int32(MKXP_SCANCODE_6)
        case 14: return Int32(MKXP_SCANCODE_7)
        case 15: return Int32(MKXP_SCANCODE_8)
        case 16: return Int32(MKXP_SCANCODE_9)

        // F-keys
        case 131: return Int32(MKXP_SCANCODE_F1)
        case 132: return Int32(MKXP_SCANCODE_F2)
        case 133: return Int32(MKXP_SCANCODE_F3)
        case 134: return Int32(MKXP_SCANCODE_F4)
        case 135: return Int32(MKXP_SCANCODE_F5)
        case 136: return Int32(MKXP_SCANCODE_F6)
        case 137: return Int32(MKXP_SCANCODE_F7)
        case 138: return Int32(MKXP_SCANCODE_F8)
        case 139: return Int32(MKXP_SCANCODE_F9)
        case 140: return Int32(MKXP_SCANCODE_F10)
        case 141: return Int32(MKXP_SCANCODE_F11)
        case 142: return Int32(MKXP_SCANCODE_F12)

        default: return nil
        }
    }
}
