import Foundation
import GameProbe
import UIKit

/// Write pipeline for imported games: metadata seeding and JGP
/// finalization after files land in the container.
enum GameImporter {

    nonisolated static func createMetadata(
        in container: GameContainer,
        profile: GameScriptProfile.Result
    ) {
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.rubyVersion = profile.rubyVersion
        metadata.rubyVersionDetectedSchema = GameScriptProfile.currentSchema.rawValue
        metadata.modernRubyScriptsDetected = profile.modernRubyScripts
        metadata.modernRubyScriptsDetectedSchema =
            GameScriptProfile.currentSchema.rawValue
        metadata.save(to: container)
    }

    nonisolated static func createMetadata(in container: GameContainer) {
        createMetadata(
            in: container,
            profile: GameScriptProfile.analyze(gameDirectory: container.gameURL)
        )
    }

    nonisolated static func seedFolderImport(in container: GameContainer) {
        let profile = GameScriptProfile.analyze(gameDirectory: container.gameURL)
        if profile.modernRubyScripts {
            persistModernRubySettings(in: container)
        }
        createMetadata(in: container, profile: profile)
    }

    private nonisolated static func persistModernRubySettings(in container: GameContainer) {
        let stateDir = container.ensureEmpoStateDirectory()
        var settings = GameSettings.load(from: stateDir)
        settings.useModernRuby = true
        settings.save(to: stateDir)
    }

    nonisolated static func preprocessJgp(at gameRoot: URL) throws -> Jgp.Bundle {
        guard let bundle = Jgp.parseBundle(at: gameRoot) else {
            throw GameImportValidator.ImportError.invalidJgpManifest
        }

        switch bundle.manifest.type {
        case .rpgmxp, .rpgmvx, .rpgmvxace, .mkxpZ:
            break
        case .unsupported(let raw):
            // The supported-engine list derives from the registered
            // cores, so registering a new core updates this copy for
            // free. Each core contributes a self-contained phrase
            // (mkxp's is "RPG Maker XP, VX, VX Ace, and mkxp-z", so
            // with one core the sentence matches the pre-cores
            // string exactly); additional cores chain on with
            // ", as well as ".
            let supported = CoreRegistry.shared.allCores
                .map { $0.supportedGamesDescription }
                .joined(separator: ", as well as ")
            throw GameImportValidator.ImportError.unsupportedRuntime(
                "This JoiPlay archive uses '\(raw)', which Empo does not support. "
                    + "Empo currently supports only \(supported) games."
            )
        }

        let fm = FileManager.default
        for name in ["manifest.json", "configuration.json"] {
            try? fm.removeItem(at: gameRoot.appendingPathComponent(name))
        }
        if let iconRel = bundle.manifest.icon, !iconRel.isEmpty {
            try? fm.removeItem(at: gameRoot.appendingPathComponent(iconRel))
        }

        return bundle
    }

    nonisolated static func finalizeJgpImport(
        container: GameContainer,
        bundle: Jgp.Bundle
    ) {
        var settings = bundle.configuration?.toGameSettings() ?? GameSettings()
        let profile = GameScriptProfile.analyze(gameDirectory: container.gameURL)

        if bundle.manifest.type == .mkxpZ {
            settings.useModernRuby = true
        } else if profile.modernRubyScripts {
            settings.useModernRuby = true
        }

        let stateDir = container.ensureEmpoStateDirectory()
        if let engineValues = bundle.configuration?.toMkxpEngineValues() {
            EngineConfigProjector.applyEngineValues(
                engineValues,
                stateDirectory: stateDir,
                gameDirectory: container.gameURL
            )
        }
        settings.save(to: stateDir)

        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.baseTitle = bundle.manifest.name
        metadata.manifestId = bundle.manifest.id
        metadata.manifestVersion = bundle.manifest.version
        metadata.manifestDescription = bundle.manifest.description
        metadata.rubyVersion = profile.rubyVersion
        metadata.rubyVersionDetectedSchema = GameScriptProfile.currentSchema.rawValue
        metadata.modernRubyScriptsDetected = profile.modernRubyScripts
        metadata.modernRubyScriptsDetectedSchema =
            GameScriptProfile.currentSchema.rawValue

        if let iconData = bundle.iconData,
            let image = UIImage(data: iconData),
            let filename = GameMetadata.saveImage(image, as: "artwork", in: container)
        {
            metadata.customArtworkFilename = filename
        }

        metadata.save(to: container)
    }
}
