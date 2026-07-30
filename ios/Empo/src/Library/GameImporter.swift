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

    /// Transient sibling of `Game/` used by `stageAndSwapGameTree`.
    /// Dot-prefixed: hidden from `GameContainer.discover` (which
    /// only lists `Games/` itself) and from casual Files browsing.
    static let updateStagingDirectoryName = ".game-update-staging"

    /// Transactional in-place update of an installed game.
    ///
    /// Builds the merged tree in a staging directory next to
    /// `Game/`, then swaps it into place atomically
    /// (`FileManager.replaceItemAt`). The staging copy of the
    /// current tree is an APFS clone (`copyItem` on one volume
    /// shares blocks), so the whole operation costs roughly the
    /// size of the *new* files, not a second copy of the game.
    ///
    /// Failure at ANY point before the swap - extraction errors,
    /// disk full mid-merge, a cancelled import - leaves the
    /// installed `Game/` byte-for-byte untouched; the staging
    /// leftovers are removed here (and `cleanupStaleUpdateStaging`
    /// sweeps any that a hard crash orphaned).
    nonisolated static func stageAndSwapGameTree(
        newTree source: URL,
        over gameURL: URL,
        fm: FileManager = .default
    ) throws {
        let staging = gameURL.deletingLastPathComponent()
            .appendingPathComponent(updateStagingDirectoryName, isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: gameURL, to: staging)
        // The clone carries the original's POSIX bits; Windows-origin
        // trees are often read-only, which would block overwrites.
        // Normalizing the clone leaves the live tree untouched.
        try GameContainer.prepareForFileReplacement(at: staging)
        try mergeMoveGameTree(from: source, into: staging, fm: fm)
        _ = try fm.replaceItemAt(gameURL, withItemAt: staging)
    }

    /// Remove staging leftovers from an update that a crash or
    /// force-quit interrupted. Called by the library scan for
    /// containers with no import in flight.
    nonisolated static func cleanupStaleUpdateStaging(
        in container: GameContainer,
        fm: FileManager = .default
    ) {
        let staging = container.url
            .appendingPathComponent(updateStagingDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: staging.path) else { return }
        NSLog(
            "[GameImporter] Removing stale update staging in %@",
            container.folderName)
        try? fm.removeItem(at: staging)
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
