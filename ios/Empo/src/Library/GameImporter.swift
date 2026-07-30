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

    /// Post-replacement metadata pass: the game files changed, so
    /// re-run script-profile detection, but keep everything the user
    /// accumulated (dateAdded, play time, custom title/artwork).
    /// Counterpart of `createMetadata` for updates of an installed
    /// game.
    nonisolated static func refreshMetadataAfterReplacement(in container: GameContainer) {
        var metadata = GameMetadata.load(from: container)
        if metadata.dateAdded == nil {
            metadata.dateAdded = Date()
        }
        metadata.refreshDetectedProfile(in: container, forceRefresh: true)
    }

    /// Move the freshly imported tree at `source` into `destination`,
    /// upgrade-in-place: a file that exists at the same relative path
    /// is overwritten by the new copy (a type conflict resolves to
    /// the new entry), and anything only present in the destination
    /// stays - saves written next to the game files, mods, and
    /// assets the new version happens not to ship. Mirrors what
    /// desktop players do when they extract a new version over an
    /// existing install.
    nonisolated static func mergeMoveGameTree(
        from source: URL,
        into destination: URL,
        fm: FileManager = .default
    ) throws {
        var destinationIsDir: ObjCBool = false
        let destinationExists = fm.fileExists(
            atPath: destination.path, isDirectory: &destinationIsDir)
        guard destinationExists, destinationIsDir.boolValue else {
            if destinationExists {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: source, to: destination)
            return
        }

        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let entryIsDir =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)

            if targetExists, targetIsDir.boolValue, entryIsDir {
                try mergeMoveGameTree(from: entry, into: target, fm: fm)
                continue
            }
            if targetExists {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: entry, to: target)
        }

        // The source directory is an empty husk now; its removal
        // failing is harmless (it lives in the import tmp dir).
        try? fm.removeItem(at: source)
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
            throw GameImportValidator.ImportError.unsupportedRuntime(
                "This JoiPlay archive uses '\(raw)', which Empo does not support. "
                    + "Empo currently supports only RPG Maker XP, VX, VX Ace, and mkxp-z games."
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

    /// `preservingExistingState` is the replacement path: the user's
    /// settings, engine overlay, custom artwork, and accumulated
    /// metadata (dateAdded, play time) stay; only the manifest
    /// fields and the re-detected script profile refresh.
    nonisolated static func finalizeJgpImport(
        container: GameContainer,
        bundle: Jgp.Bundle,
        preservingExistingState: Bool = false
    ) {
        let profile = GameScriptProfile.analyze(gameDirectory: container.gameURL)

        if !preservingExistingState {
            var settings = bundle.configuration?.toGameSettings() ?? GameSettings()
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
        }

        var metadata =
            preservingExistingState ? GameMetadata.load(from: container) : GameMetadata()
        if metadata.dateAdded == nil {
            metadata.dateAdded = Date()
        }
        metadata.baseTitle = bundle.manifest.name
        metadata.manifestId = bundle.manifest.id
        metadata.manifestVersion = bundle.manifest.version
        metadata.manifestDescription = bundle.manifest.description
        metadata.rubyVersion = profile.rubyVersion
        metadata.rubyVersionDetectedSchema = GameScriptProfile.currentSchema.rawValue
        metadata.modernRubyScriptsDetected = profile.modernRubyScripts
        metadata.modernRubyScriptsDetectedSchema =
            GameScriptProfile.currentSchema.rawValue

        let mayWriteArtwork =
            !preservingExistingState || metadata.customArtworkFilename == nil
        if mayWriteArtwork,
            let iconData = bundle.iconData,
            let image = UIImage(data: iconData),
            let filename = GameMetadata.saveImage(image, as: "artwork", in: container)
        {
            metadata.customArtworkFilename = filename
        }

        metadata.save(to: container)
    }
}
