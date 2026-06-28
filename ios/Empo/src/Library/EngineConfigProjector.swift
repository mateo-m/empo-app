import Foundation
import GameProbe

/// Merges `GameSettings` overrides into the per-game managed
/// `EmpoState/mkxp.json` and reads developer defaults from
/// `Game/mkxp.json`.
enum EngineConfigProjector {
    private static let configFilename = "mkxp.json"

    static func readGameDefaults(from gameDirectory: URL) -> GameConfigDefaults {
        let sourceURL = gameDirectory.appendingPathComponent(configFilename)

        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
            let config = parseJSONWithComments(raw)
        else {
            return GameConfigDefaults()
        }

        let enableHires = config["enableHires"] as? Bool ?? false
        let scalingFactor =
            (config["framebufferScalingFactor"] as? Double)
            ?? (config["framebufferScalingFactor"] as? Int).map(Double.init)
            ?? 1.0
        let renderScale: RenderScale? =
            if enableHires {
                switch scalingFactor {
                case ..<1.5: RenderScale.x1
                case ..<3.0: RenderScale.x2
                default: RenderScale.x4
                }
            } else {
                nil
            }

        let solidFontsArray = config["solidFonts"] as? [String]
        let solidFontsEnabled: Bool? = solidFontsArray.map { !$0.isEmpty }

        return GameConfigDefaults(
            smoothScaling: (config["smoothScaling"] as? Int).map { $0 != 0 },
            fixedAspectRatio: config["fixedAspectRatio"] as? Bool,
            renderScale: renderScale,
            frameSkip: config["frameSkip"] as? Bool,
            vsync: (config["syncToRefreshrate"] as? Bool)
                ?? (config["vsync"] as? Bool),
            pathCache: config["pathCache"] as? Bool,
            fontScale: config["fontScale"] as? Double,
            solidFonts: solidFontsEnabled
        )
    }

    static func apply(
        settings: GameSettings,
        stateDirectory: URL,
        gameDirectory: URL
    ) {
        let configURL = stateDirectory.appendingPathComponent(configFilename)
        let sourceURL = gameDirectory.appendingPathComponent(configFilename)

        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: sourceURL.path),
            let raw = try? String(contentsOf: sourceURL, encoding: .utf8),
            let parsed = parseJSONWithComments(raw)
        {
            config = parsed
        }

        config.removeValue(forKey: "syntaxTransform")

        if let v = settings.smoothScaling { config["smoothScaling"] = v ? 1 : 0 }
        if let v = settings.fixedAspectRatio { config["fixedAspectRatio"] = v }
        if let v = settings.frameSkip { config["frameSkip"] = v }
        if let v = settings.fontScale { config["fontScale"] = v }
        config.removeValue(forKey: "vsync")
        if let v = settings.vsync { config["syncToRefreshrate"] = v }
        if let v = settings.pathCache { config["pathCache"] = v }

        config.removeValue(forKey: "defScreenW")
        config.removeValue(forKey: "defScreenH")
        if let scale = settings.renderScale {
            if scale.enableHires {
                config["enableHires"] = true
                config["framebufferScalingFactor"] = scale.framebufferScalingFactor
            } else {
                config["enableHires"] = false
                config.removeValue(forKey: "framebufferScalingFactor")
            }
        }

        if let v = settings.solidFonts {
            config["solidFonts"] = v ? ["*"] : [] as [String]
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
            let jsonString = String(data: data, encoding: .utf8)
        {
            try? jsonString.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private static func parseJSONWithComments(_ raw: String) -> [String: Any]? {
        JSON5LiteParser.parseObject(raw)
    }
}
