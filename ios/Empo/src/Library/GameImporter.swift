import Foundation
import GameProbe
import UIKit

/// Write pipeline for imported games: metadata seeding and JGP
/// finalization after files land in the container.
enum GameImporter {

    nonisolated static func createMetadata(in container: GameContainer) {
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.save(to: container)
    }

    /// Post-replacement metadata pass: keep everything the user
    /// accumulated (dateAdded, play time, custom title/artwork).
    /// Counterpart of `createMetadata` for updates of an installed
    /// game.
    nonisolated static func refreshMetadataAfterReplacement(in container: GameContainer) {
        var metadata = GameMetadata.load(from: container)
        guard metadata.dateAdded == nil else { return }
        metadata.dateAdded = Date()
        metadata.save(to: container)
    }

    /// Transactional in-place update of an installed game: the new
    /// tree merges into a staging copy of `Game/` (same-path files
    /// overwritten, everything else kept) and swaps in atomically.
    /// Any failure before the swap leaves the installed `Game/`
    /// byte-for-byte untouched. Semantics live in GameProbe's
    /// `GameTreeUpdate` so the Linux CI tests exercise them. This
    /// wrapper only exists so pipeline call sites read app-domain
    /// language.
    nonisolated static func stageAndSwapGameTree(
        newTree source: URL,
        over gameURL: URL,
        fm: FileManager = .default
    ) throws {
        try GameTreeUpdate.stageAndSwap(newTree: source, over: gameURL, fm: fm)
    }

    /// Recover from an update that a crash or force-quit
    /// interrupted, then remove its leftovers. If the crash hit the
    /// swap between its two renames (no `Game/` on disk), the tree
    /// is restored from the staged/backup artifacts BEFORE anything
    /// is swept - otherwise the scan's orphan cleanup would delete
    /// the container, saves included. Called by the library scan
    /// for containers with no import in flight.
    nonisolated static func cleanupStaleUpdateStaging(
        in container: GameContainer,
        fm: FileManager = .default
    ) {
        let outcome = GameTreeUpdate.sweepInterruptedUpdate(target: container.gameURL, fm: fm)
        if let restoredFrom = outcome.restoredFrom {
            NSLog(
                "[GameImporter] Restored %@ of %@ from interrupted update artifact %@",
                container.gameURL.lastPathComponent,
                container.folderName,
                restoredFrom)
        }
        for name in outcome.removed {
            NSLog(
                "[GameImporter] Removed stale update leftover %@ in %@",
                name,
                container.folderName)
        }
    }

    nonisolated static func preprocessJgp(at gameRoot: URL) throws -> Jgp.Bundle {
        guard let bundle = Jgp.parseBundle(at: gameRoot) else {
            throw GameImportValidator.ImportError.invalidJgpManifest
        }

        let type = bundle.manifest.type
        guard GameCores.all.contains(where: { $0.joiPlayTypes.contains(type) }) else {
            let games = GameCores.all.compactMap(\.joiPlayGames).joined(separator: " and ")
            throw GameImportValidator.ImportError.unsupportedRuntime(
                "This JoiPlay archive uses '\(type)', which Empo does not support. "
                    + "Empo imports only JoiPlay archives of \(games)."
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
    /// metadata (dateAdded, play time) stay. Only the manifest
    /// fields refresh.
    nonisolated static func finalizeJgpImport(
        container: GameContainer,
        bundle: Jgp.Bundle,
        preservingExistingState: Bool = false
    ) {
        if !preservingExistingState {
            let settings = bundle.configuration?.toGameSettings() ?? GameSettings()
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
