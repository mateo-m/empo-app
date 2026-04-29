import Foundation
import UIKit
import SwiftUI
import Observation
import Synchronization

/// In-flight import that's still in its pre-flight validation phase.
/// Once the pre-flight passes, the matching `GameEntry` is appended
/// to `games` with `.importing(progress:)` status and the pending
/// entry is cleared - progress from that point on lives on the real
/// game card/row. On any pre-flight failure, the pending entry is
/// dropped without the user ever seeing a half-broken skeleton.
///
/// Rendering of the validating state is delegated to the call site:
/// when the library is empty the Import button hoists it onto its
/// own label; when the library already has games the grid/list
/// renders a synthetic card via `syntheticEntry` so the status
/// feedback stays anchored where the user expects it.
struct PendingImport: Identifiable, Hashable {
    let id: String
    let sourceName: String

    /// Placeholder `GameEntry` used when rendering the pending
    /// import inside the existing grid/list. Container is nil
    /// because nothing is on disk yet; `progress: 0` renders as
    /// the indeterminate spinner inside `GameStatusIndicator`,
    /// which is the right visual read for the pre-flight phase.
    var syntheticEntry: GameEntry {
        GameEntry(
            id: id,
            container: nil,
            title: sourceName,
            artworkPath: nil,
            status: .importing(progress: 0)
        )
    }
}


@MainActor @Observable
class GameLibrary {
    static let shared = GameLibrary()

    var games: [GameEntry] = []
    var pendingImports: [String: PendingImport] = [:]

    private let fm = FileManager.default
    private let cancelledImports = Mutex(Set<String>())

    /// IDs of imports currently extracting / moving on a detached
    /// task. The library scan skips these so a concurrent reload
    /// (triggered by another import finishing) doesn't see a
    /// half-imported container - i.e. one where the destination
    /// folder exists but the inner `Game/` subdir hasn't landed
    /// yet - and surface it as an `.invalid` "Unknown Game" entry,
    /// clobbering the in-memory progress card via the
    /// scan/merge replace step in `reload()`.
    private let inFlightImports = Mutex(Set<String>())

    nonisolated static var gamesDirectory: URL { GameContainer.rootURL }

    private init() {
        ensureGamesDirectory()
        // Initial scan runs off-main via reload(). The library is
        // observable and empty until the scan completes, which keeps
        // first render of the library instant on cold storage.
        reload(initialLoad: true)
    }


    func reload(initialLoad: Bool = false) {
        let cleanupInvalid = initialLoad
            ? UserDefaults.standard.bool(forKey: DefaultsKey.cleanupInvalidGames)
            : false
        let skipIDs = inFlightImports.withLock { Set($0) }
        Task.detached {
            let scanned = GameLibrary.scanGames(
                cleanupInvalid: cleanupInvalid,
                skipIDs: skipIDs
            )
            let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

            await MainActor.run {
                let lib = GameLibrary.shared
                withAnimation {
                    var updatedIDs = Set<String>()
                    for i in lib.games.indices {
                        let id = lib.games[i].id
                        if let fresh = scannedByID[id] {
                            if lib.games[i] != fresh {
                                lib.games[i] = fresh
                            }
                            updatedIDs.insert(id)
                        }
                    }

                    lib.games.removeAll { !$0.isImporting && !scannedByID.keys.contains($0.id) }

                    for entry in scanned where !updatedIDs.contains(entry.id) {
                        lib.games.append(entry)
                    }
                }
            }
        }
    }

    /// Scan `Documents/Games/`. Each subfolder that parses as a
    /// `GameContainer` becomes a candidate; folders whose name
    /// doesn't begin with a parseable UUID are ignored entirely
    /// (defends against orphan files / dev-era leftovers).
    ///
    /// `cleanupInvalid: true` removes containers that fail
    /// validation; otherwise they're surfaced as `.invalid` cards
    /// so the user can choose to delete them.
    nonisolated private static func scanGames(
        fm: FileManager = .default,
        cleanupInvalid: Bool,
        skipIDs: Set<String> = []
    ) -> [GameEntry] {
        var entries: [GameEntry] = []

        for container in GameContainer.discover() {
            // Skip containers whose import is still in-flight on
            // another task. Without this guard a concurrent reload
            // - triggered by a sibling import finishing - would see
            // the partially-populated folder, decide it's invalid,
            // and produce an "Unknown Game" card that clobbers the
            // in-memory progress card during the merge step.
            if skipIDs.contains(container.id) { continue }

            // The Game/ subdir must exist for the import to be
            // meaningful. If it doesn't, the container is either
            // half-imported or layout-incompatible (e.g. a folder
            // from a build before this layout existed).
            let gameDirExists = fm.fileExists(atPath: container.gameURL.path)
            let isValid = gameDirExists
                && (try? GameImportValidator.validate(container.gameURL)) != nil

            if !isValid {
                if cleanupInvalid {
                    NSLog("[GameLibrary] Removing invalid game container: %@",
                          container.folderName)
                    try? container.deleteAll()
                    continue
                }
                if var entry = buildGameEntry(from: container, fm: fm) {
                    entry.status = .invalid
                    entries.append(entry)
                }
                continue
            }

            if let entry = buildGameEntry(from: container, fm: fm) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    nonisolated private static func buildGameEntry(
        from container: GameContainer,
        fm: FileManager = .default
    ) -> GameEntry? {
        let iniTitle = GameEntry.parseINITitle(at: container.gameURL) ?? "Unknown Game"
        let defaultArtwork = findArtwork(in: container)

        let metadata = GameMetadata.load(from: container)
        // Title priority: user's customTitle > import-time baseTitle
        // (JGP manifest name) > Game.ini title. The `engineTitle`
        // subtitle on the library card only surfaces when the user
        // has explicitly set a `customTitle` that diverges from the
        // engine's Game.ini title - so we can show both their
        // chosen name and what the game calls itself. JGP imports
        // deliberately use the manifest as the authoritative title
        // and don't show a subtitle; JoiPlay's chosen name is THE
        // name, and surfacing Game.ini alongside would just clutter
        // the card with a near-duplicate.
        let baseTitle = metadata.baseTitle ?? iniTitle
        let title = metadata.customTitle ?? baseTitle
        let artworkPath = metadata.customArtworkPath(in: container) ?? defaultArtwork
        let engineTitle: String? = {
            guard metadata.customTitle != nil else { return nil }
            return title != iniTitle ? iniTitle : nil
        }()

        return GameEntry(
            id: container.id,
            container: container,
            title: title,
            artworkPath: artworkPath,
            engineTitle: engineTitle,
            lastPlayed: metadata.lastPlayed
        )
    }

    /// Comparator used to decide whether to surface the engine's
    /// Game.ini title on a library card. Strips diacritics and
    /// case-folds so cosmetically-equivalent names ("Pokemon
    /// Reborn" vs "Pokémon Reborn") don't produce a nearly-
    /// duplicate subtitle. Trailing/leading whitespace is also
    /// ignored so a stray newline in Game.ini doesn't trip it.
    nonisolated private static func titlesMeaningfullyDiffer(_ a: String, _ b: String) -> Bool {
        let folded: (String) -> String = { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "en_US_POSIX"))
        }
        return folded(a) != folded(b)
    }


    func refreshGameEntry(id: String) {
        guard let idx = games.firstIndex(where: { $0.id == id }),
              let container = games[idx].container else { return }
        guard var entry = Self.buildGameEntry(from: container) else { return }
        entry.status = games[idx].status  // preserve current status
        withAnimation { games[idx] = entry }
    }


    private struct ImportCancelled: Error {}

    /// Errors surfaced from the import pipeline with display-ready
    /// messages. Used to remap low-level Foundation errors (disk
    /// full, permission denied) into text the user can act on.
    enum ImportError: LocalizedError {
        case outOfSpace

        var errorDescription: String? {
            switch self {
            case .outOfSpace:
                return "Not enough space to import. Free up space on your device and try again."
            }
        }
    }

    /// True when `error` is the Foundation / POSIX flavor of "disk
    /// full". Covers both `NSFileWriteOutOfSpaceError` (from
    /// FileManager writes) and `ENOSPC` (from libc-level calls that
    /// libarchive bubbles up as NSError).
    nonisolated private static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) {
            return true
        }
        return false
    }

    nonisolated private func isImportCancelled(_ id: String) -> Bool {
        cancelledImports.withLock { $0.contains(id) }
    }

    nonisolated private func cancelImport(_ id: String) {
        cancelledImports.withLock { _ = $0.insert(id) }
    }

    nonisolated private func clearCancellation(_ id: String) {
        cancelledImports.withLock { _ = $0.remove(id) }
    }

    /// Cancel an import that's still in its pre-validation phase
    /// (visible only via `pendingImports`). The detached task sees
    /// the cancellation flag at its next checkpoint, unwinds temp
    /// files, and removes the pending entry.
    func cancelPendingImport(_ importID: String) {
        cancelImport(importID)
    }

    func importGame(from sourceURL: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        ensureGamesDirectory()

        let archiveFormat = ArchiveExtractor.Format(extension: sourceURL.pathExtension)
        let importID = UUID().uuidString
        let sourceName = archiveFormat == nil
            ? sourceURL.lastPathComponent
            : sourceURL.deletingPathExtension().lastPathComponent

        // Pre-flight phase: button shows "Validating", library keeps
        // its current UI (empty state or existing list). Once
        // pre-flight passes a progress card is committed to `games` and
        // extraction/finalisation runs with the card visible.
        pendingImports[importID] = PendingImport(id: importID, sourceName: sourceName)
        // Mark the import as in-flight so concurrent library scans
        // (triggered by sibling imports finishing) skip this
        // container until the move is committed and metadata is
        // written. Removed in the detached task's defer.
        inFlightImports.withLock { _ = $0.insert(importID) }

        Task.detached(priority: .userInitiated) {
            defer { self.clearCancellation(importID) }
            // Drop from in-flight set BEFORE queuing the reload
            // call so the post-completion scan sees this container
            // as a normal candidate (not skipped). Doing this in a
            // `defer` would push it past the `await MainActor.run`
            // closure and reload's scan would still treat the
            // just-finished import as in-flight, leaving the card
            // stuck on `.importing` forever.
            let markNotInFlight = {
                self.inFlightImports.withLock { _ = $0.remove(importID) }
            }
            do {
                if archiveFormat != nil {
                    try self.importArchive(from: sourceURL, importID: importID, sourceName: sourceName)
                } else {
                    try self.importFolder(from: sourceURL, importID: importID, sourceName: sourceName)
                }
                markNotInFlight()
                await MainActor.run {
                    GameLibrary.shared.reload()
                    completion(nil)
                }
            } catch is ImportCancelled {
                markNotInFlight()
                NSLog("[GameLibrary] Import cancelled: %@", importID)
                await MainActor.run {
                    _ = GameLibrary.shared.pendingImports.removeValue(forKey: importID)
                    GameLibrary.shared.games.removeAll { $0.id == importID }
                }
            } catch {
                markNotInFlight()
                NSLog("[GameLibrary] Import error: %@", "\(error)")
                let surfaced: Error = Self.isOutOfSpace(error) ? ImportError.outOfSpace : error
                await MainActor.run {
                    _ = GameLibrary.shared.pendingImports.removeValue(forKey: importID)
                    GameLibrary.shared.games.removeAll { $0.id == importID }
                    completion(surfaced)
                }
            }
        }
    }

    /// Commits a progress-card `GameEntry` to `games` and drops the
    /// matching pending entry. Called from the import pipeline once
    /// pre-flight validation passes - from this point on the user
    /// can see and cancel the import from the card itself.
    nonisolated private func commitPendingToCard(
        _ importID: String,
        container: GameContainer,
        title: String,
        artworkPath: String?
    ) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            withAnimation {
                _ = lib.pendingImports.removeValue(forKey: importID)
                lib.games.append(GameEntry(
                    id: importID,
                    container: container,
                    title: title,
                    artworkPath: artworkPath,
                    status: .importing(progress: 0)
                ))
            }
        }
    }

    /// Swap in the card's artwork mid-extract, once the archive
    /// has yielded a `Graphics/Titles/*` image or `.exe` icon.
    /// Called more than once per import: each time the extractor
    /// finds an alphabetically-smaller candidate the card updates
    /// to match, mirroring the rule used by `findArtwork` after
    /// the full extract completes so the card doesn't flicker to
    /// a different artwork when the import finishes. Rebuilding
    /// the entry (rather than mutating `artworkPath` on the
    /// existing one) goes through SwiftUI's normal diffing so the
    /// card cross-fades the placeholder to the real artwork.
    nonisolated private func updateCardArtwork(_ importID: String, artworkPath: String) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            // No early-return on same path. The mid-extract sidecar
            // is at a fixed location (`<container>/Metadata/exe-icon.png`)
            // and gets overwritten on disk when a later .exe in the
            // archive supersedes the earlier pick (e.g. Reborn1950
            // ships [Patcher.exe (skipped), Reborn.exe, Game.exe] -
            // Reborn writes first, Game.exe overwrites). The path
            // string is unchanged across those writes so a guard
            // here would skip the SwiftUI re-render and the card
            // would keep showing the first icon decoded into the
            // ImageCache - until reload-time view rebuild swaps it
            // for the latest disk content, producing a visible
            // mid-import-vs-final mismatch. Always rebuilding the
            // entry forces the body re-eval, which re-reads cache
            // (already evicted at write time), so the displayed
            // icon tracks disk state.
            withAnimation {
                lib.games[idx] = GameEntry(
                    id: importID,
                    container: lib.games[idx].container,
                    title: lib.games[idx].title,
                    artworkPath: artworkPath,
                    engineTitle: lib.games[idx].engineTitle,
                    lastPlayed: lib.games[idx].lastPlayed,
                    status: lib.games[idx].status
                )
            }
        }
    }

    /// Updates the extraction progress on the already-committed
    /// progress card (not on `pendingImports`, which was cleared
    /// once pre-flight passed).
    nonisolated private func updateCardProgress(_ importID: String, _ progress: Double) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            lib.games[idx].status = .importing(progress: progress)
        }
    }

    nonisolated private func importFolder(from sourceURL: URL, importID: String, sourceName: String) throws {
        let fm = FileManager.default
        let folderName = sourceURL.lastPathComponent

        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tmpDest = tmpDir.appendingPathComponent(folderName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Pre-flight: copy once into tmp (cheaper than moving the
        // source and having no rollback if validation fails) and
        // validate the copy. This is the only "Validating" phase
        // the user sees on the button.
        try fm.copyItem(at: sourceURL, to: tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        try GameImportValidator.validate(tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        // Pre-flight passed - commit the progress card so the rest
        // of the import has a visible home for progress/cancel UI.
        let title = GameEntry.parseINITitle(at: tmpDest) ?? sourceName
        let container = GameContainer(id: importID, slug: GameContainer.slugify(title))

        // Lazy: write the exe-icon sidecar into Metadata/ from the
        // tmp tree before the move, so the committed card has
        // something to display. ExecutableIconExtractor's static
        // helper is keyed off a game-folder URL; pass the tmp
        // location, then re-target the resulting sidecar path
        // afterwards. (For folder imports, sidecars are uncommon
        // because folder imports are usually pre-extracted RGSS
        // trees with `Graphics/Titles/` already present.)
        let artworkPath = Self.findFolderImportArtwork(at: tmpDest)
        if let path = artworkPath {
            // Warm the decode cache before `tmpDest`'s defer-backed
            // cleanup kicks in so the card keeps rendering the
            // artwork across the move-then-reload window.
            _ = ImageCache.shared.image(for: path)
        }
        commitPendingToCard(importID, container: container,
                            title: title, artworkPath: artworkPath)

        // Folder imports don't have a meaningful extraction-progress
        // phase (the heavy copy already happened in the pre-flight).
        // Jump directly to the move; if the card gets cancelled in
        // the brief window before the move finishes, the cancel
        // path below cleans up.
        updateCardProgress(importID, 1.0)

        try fm.createDirectory(at: container.url, withIntermediateDirectories: true)
        try fm.moveItem(at: tmpDest, to: container.gameURL)

        var committed = false
        defer {
            if !committed {
                try? container.deleteAll()
            }
        }

        if isImportCancelled(importID) { throw ImportCancelled() }

        Self.detectAndPersistModernRuby(in: container)

        // Lazy: extract the exe-icon sidecar from the now-final
        // location, writing into Metadata/. Idempotent (skipped if
        // already present), so repeat imports are cheap.
        _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)

        Self.createMetadata(in: container)
        committed = true
    }

    nonisolated private func importArchive(from sourceURL: URL, importID: String, sourceName: String) throws {
        let fm = FileManager.default

        // Pre-flight scratch: throwaway dir for selectively
        // extracting just the validation files. Lives only for the
        // length of the pre-flight phase.
        let preflightDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: preflightDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: preflightDir) }

        let preflightRoot: URL
        do {
            preflightRoot = try GameImportValidator.preflightArchive(
                at: sourceURL,
                scratchDir: preflightDir,
                shouldCancel: { self.isImportCancelled(importID) }
            )
        } catch ArchiveExtractor.Error.cancelled {
            throw ImportCancelled()
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        // Pre-flight passed - pick up the title from the extracted
        // `.ini` so the committed card shows the real name while the
        // rest of the archive extracts in the background. Artwork
        // fills in mid-extract via the extract() callback below.
        let title = GameEntry.parseINITitle(at: preflightRoot) ?? sourceName
        let container = GameContainer(id: importID, slug: GameContainer.slugify(title))
        commitPendingToCard(importID, container: container,
                            title: title, artworkPath: nil)

        // Full extraction now runs visibly - progress feeds the
        // committed card's `.importing(progress:)` status.
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Mid-extract artwork surfacing - .exe icon ONLY.
        //
        // Earlier this also surfaced `Graphics/Titles/*` images as
        // a fallback when no `.exe` had landed yet. That produced
        // a visible artwork flash for games whose archive ordering
        // happened to put title images before the executable
        // (Reborn1950.zip is one such): mid-import would show the
        // title screen, then late-extract or post-import reload
        // would replace it with the `.exe` icon that
        // `findArtwork` actually picks. The two-stage surface
        // never matched what the user would see post-import, so
        // we just don't surface the titles fallback during
        // extract anymore. Games without a usable `.exe` keep
        // the placeholder during import and transition once at
        // reload (placeholder -> title screen). Games with an
        // `.exe` still surface the icon as soon as the `.exe`
        // entry is processed, and that surface matches what the
        // post-import scan picks - one transition, no flash.
        //
        // `Game.exe` is the canonical RPG Maker default and wins
        // outright when present; other qualifying `.exe`s set a
        // tentative sidecar that `Game.exe` can still overwrite
        // if it arrives later in archive order. Utility binaries
        // (patchers, launchers, unins000.exe, etc.) are skipped
        // wholesale via the keyword blocklist.
        //
        // Sidecar lives at `<container>/Metadata/exe-icon.png`,
        // not inside `Game/`, so the imported game tree stays
        // untouched and the file survives the tmp->destination
        // move unchanged.
        let exeArtworkLocked = Mutex(false)
        let hasTentativeExeArtwork = Mutex(false)
        do {
            try ArchiveExtractor.extract(
                archive: sourceURL,
                to: tmpDir,
                shouldCancel: { self.isImportCancelled(importID) },
                progress: { _, pct in
                    self.updateCardProgress(importID, pct)
                },
                onFileWritten: { relative, diskURL in
                    let lower = relative.lowercased()
                    let filename = (relative as NSString).lastPathComponent

                    // Only react to root-level executables (depth
                    // 0 or 1, matching the archive's optional
                    // wrapper folder).
                    guard lower.hasSuffix(".exe") else { return }
                    let components = lower.split(separator: "/", omittingEmptySubsequences: false)
                    let depth = components.count - 1
                    guard depth <= 1 else { return }
                    if exeArtworkLocked.withLock({ $0 }) { return }

                    let isGameExe = filename.lowercased() == "game.exe"
                    if !isGameExe, ExecutableIconExtractor.isUtilityExecutable(filename: filename) {
                        return
                    }
                    // Non-canonical binaries defer to any
                    // previously-written tentative sidecar; only
                    // `Game.exe` overwrites.
                    if !isGameExe, hasTentativeExeArtwork.withLock({ $0 }) { return }

                    guard let data = try? Data(contentsOf: diskURL, options: .mappedIfSafe) else {
                        return
                    }
                    guard let pe = PEImage(data: data),
                          let image = pe.extractIcon(),
                          let png = image.pngData() else {
                        return
                    }

                    container.ensureMetadataDirectory()
                    let sidecarURL = container.exeIconSidecarURL
                    do {
                        try png.write(to: sidecarURL)
                    } catch {
                        NSLog("[GameLibrary] Sidecar write failed: %@", "\(error)")
                        return
                    }
                    ImageCache.shared.evict(path: sidecarURL.path)
                    _ = ImageCache.shared.image(for: sidecarURL.path)

                    hasTentativeExeArtwork.withLock { $0 = true }
                    if isGameExe {
                        exeArtworkLocked.withLock { $0 = true }
                    }
                    self.updateCardArtwork(importID, artworkPath: sidecarURL.path)
                }
            )
        } catch ArchiveExtractor.Error.cancelled {
            throw ImportCancelled()
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try GameLibrary.findGameRoot(in: tmpDir)

        // JGP post-processing: if the archive was a JoiPlay .jgp,
        // parse manifest/configuration/gamepad, reject unsupported
        // runtimes, strip the JGP-specific files from the game
        // folder so they don't ship next to the engine files, and
        // keep a `JgpImport` bundle so we can seed metadata +
        // settings after the final move. Regular .zip imports skip
        // this branch entirely.
        let jgpBundle: Jgp.Bundle? = sourceURL.pathExtension.lowercased() == "jgp"
            ? try Self.preprocessJgp(at: gameRoot)
            : nil

        // Move the extracted tree into <container>/Game/. The
        // exe-icon sidecar (if written above) already lives at
        // <container>/Metadata/exe-icon.png and survives this move
        // unchanged because Metadata/ is a sibling of Game/.
        try fm.createDirectory(at: container.url, withIntermediateDirectories: true)
        try fm.moveItem(at: gameRoot, to: container.gameURL)

        var committed = false
        defer {
            if !committed {
                try? container.deleteAll()
            }
        }

        if isImportCancelled(importID) { throw ImportCancelled() }
        if let bundle = jgpBundle {
            Self.finalizeJgpImport(
                container: container,
                bundle: bundle
            )
        } else {
            Self.createMetadata(in: container)
        }
        committed = true
    }

    /// JoiPlay .jgp post-extract step. Parses the three JSON
    /// sidecars, rejects unsupported runtimes, and removes the
    /// sidecars + icon from the game folder so the runtime sees a
    /// clean RGSS tree. The returned `Bundle` carries everything
    /// we need to seed metadata + settings once the folder is
    /// moved to its final destination.
    nonisolated private static func preprocessJgp(at gameRoot: URL) throws -> Jgp.Bundle {
        guard let bundle = Jgp.parseBundle(at: gameRoot) else {
            throw GameImportValidator.ImportError.invalidJgpManifest
        }

        switch bundle.manifest.type {
        case .rpgmxp, .rpgmvx, .rpgmvxace, .mkxpZ:
            break
        case .unsupported(let raw):
            throw GameImportValidator.ImportError.unsupportedRuntime(
                "This JoiPlay archive uses '\(raw)' which isn't supported. "
                + "Only RPG Maker XP, VX, VX Ace, and mkxp-z games are currently supported."
            )
        }

        let fm = FileManager.default
        for name in ["manifest.json", "configuration.json", "gamepad.json"] {
            try? fm.removeItem(at: gameRoot.appendingPathComponent(name))
        }
        if let iconRel = bundle.manifest.icon, !iconRel.isEmpty {
            try? fm.removeItem(at: gameRoot.appendingPathComponent(iconRel))
        }

        return bundle
    }

    /// Seed metadata + per-game settings + per-game control layout
    /// for a freshly-imported JGP. Runs on the import thread after
    /// the game folder is at its permanent destination so all
    /// side-effect paths (game_settings.json, mkxp.json, metadata
    /// sidecar, UserDefaults layout key) use the final locations.
    nonisolated private static func finalizeJgpImport(
        container: GameContainer,
        bundle: Jgp.Bundle
    ) {
        // Seed engine settings from the bundled configuration.
        var settings = bundle.configuration?.toGameSettings() ?? GameSettings()

        // Ruby-syntax detection. JoiPlay's "mkxp-z" runtime
        // label plus Reborn-style bootstrap games ship actual
        // Ruby 3 source, so force useModernRuby for those. For
        // other runtime types we scan `.rb` files for Ruby 3
        // markers as a fallback - catches PE v20+ games that
        // still tag themselves as rpgmxp but have been ported
        // to the modern Essentials codebase.
        if bundle.manifest.type == .mkxpZ {
            settings.useModernRuby = true
        } else if GameSettings.detectModernRubyScripts(in: container.gameURL) {
            settings.useModernRuby = true
        }

        // Persist managed config (mkxp.json, game_settings.json)
        // into <container>/EmpoState/. applyToConfig reads the
        // developer's source from `Game/mkxp.json` directly (the
        // imported folder is treated as immutable), so no snapshot
        // step is needed.
        let stateDir = container.ensureEmpoStateDirectory()
        settings.applyToConfig(stateDirectory: stateDir, gameDirectory: container.gameURL)
        settings.save(to: stateDir)

        // Seed the per-game control layout from the JGP gamepad
        // hints. Users can still re-arrange in the player toolbar
        // afterwards and their edits override this seed.
        if let gamepad = bundle.gamepad {
            let seed = gamepad.toSeedLayout()
            ControlsLayout.writeInitialPerGameLayout(
                gameID: container.id,
                dpadCenter: seed.dpadCenter,
                dpadSize: seed.dpadSize,
                buttons: seed.buttons
            )
        }

        // Metadata carries manifest fields and the JGP icon (if
        // present) as custom artwork so the library card shows
        // JoiPlay's canonical branding for the game. The manifest
        // name becomes the BASE title (not a custom override) -
        // the library resolves title as customTitle ?? baseTitle ??
        // iniTitle, so the user still sees the manifest name first
        // but can type their own customTitle on top if desired,
        // and Game.ini's title stays available as the final
        // fallback when there's no manifest.
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.baseTitle = bundle.manifest.name
        metadata.manifestId = bundle.manifest.id
        metadata.manifestVersion = bundle.manifest.version
        metadata.manifestDescription = bundle.manifest.description

        if let iconData = bundle.iconData,
           let image = UIImage(data: iconData),
           let filename = GameMetadata.saveImage(image, as: "artwork", in: container) {
            metadata.customArtworkFilename = filename
        }

        metadata.save(to: container)
    }

    nonisolated private static func createMetadata(in container: GameContainer) {
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.save(to: container)
    }

    /// Scans the freshly-extracted game folder for Ruby 3 syntax
    /// markers and persists `useModernRuby: true` + updates
    /// mkxp.json if any are found. A no-op for classical PE
    /// fangames written in Ruby 1.8 - the heuristic only fires on
    /// games that actually ship Ruby 3 source (Reborn 19.5+,
    /// PE v20+, anything built on modern Essentials). JGP imports
    /// have their own detection path in `finalizeJgpImport` that
    /// also honors the manifest's runtime hint; this helper covers
    /// the plain .zip / folder import path.
    nonisolated private static func detectAndPersistModernRuby(in container: GameContainer) {
        guard GameSettings.detectModernRubyScripts(in: container.gameURL) else { return }
        let stateDir = container.ensureEmpoStateDirectory()
        var settings = GameSettings.load(from: stateDir)
        settings.useModernRuby = true
        settings.applyToConfig(stateDirectory: stateDir, gameDirectory: container.gameURL)
        settings.save(to: stateDir)
    }


    func deleteGame(_ entry: GameEntry, onError: (@MainActor @Sendable (String) -> Void)? = nil) {
        let wasImporting = entry.isImporting

        if let artworkPath = entry.artworkPath {
            ImageCache.shared.evict(path: artworkPath)
        }

        withAnimation {
            games.removeAll { $0.id == entry.id }
        }

        if wasImporting {
            cancelImport(entry.id)
            // In-flight imports may have partially-created container
            // dirs; clean them up if present (no-op when nothing
            // landed on disk yet).
            if let container = entry.container {
                Task.detached(priority: .userInitiated) {
                    try? container.deleteAll()
                }
            }
            return
        }

        guard let container = entry.container else { return }
        Task.detached(priority: .userInitiated) {
            do {
                guard FileManager.default.fileExists(atPath: container.url.path) else { return }
                // One rm -rf nukes Game/, EmpoState/, Logs/, and
                // Metadata/ together - per-game saves, settings,
                // logs, custom artwork, and crash markers all go
                // in a single call.
                try container.deleteAll()
            } catch {
                NSLog("[GameLibrary] Delete error: %@", "\(error)")
                await MainActor.run {
                    GameLibrary.shared.reload()
                    onError?(error.localizedDescription)
                }
            }
        }
    }


    nonisolated private static func findArtwork(in container: GameContainer) -> String? {
        let fm = FileManager.default

        // Prefer the pre-extracted `.exe` icon when available. The
        // sidecar lives in `<container>/Metadata/exe-icon.png`
        // (kept out of `Game/` so the imported tree stays
        // untouched). It's written once at import time (or lazily
        // on-demand below) and carries the "official" game icon
        // the developer shipped inside the executable. Only fall
        // through to `Graphics/Titles/` when no icon could be
        // produced.
        let sidecar = container.exeIconSidecarURL
        if fm.fileExists(atPath: sidecar.path) {
            return sidecar.path
        }
        if let sidecarPath = ExecutableIconExtractor.writeSidecarIfPossible(in: container) {
            return sidecarPath
        }

        return findTitlesArtwork(in: container.gameURL)
    }

    /// Pre-import folder-tree variant of `findArtwork` that looks
    /// inside a tmp directory (not yet inside a container).
    /// Mirrors the post-import rule for the Graphics/Titles
    /// fallback only - exe-icon sidecars are produced after the
    /// move into the container.
    nonisolated private static func findFolderImportArtwork(at url: URL) -> String? {
        return findTitlesArtwork(in: url)
    }

    nonisolated private static func findTitlesArtwork(in gameURL: URL) -> String? {
        let titlesDir = gameURL.appendingPathComponent("Graphics/Titles")
        guard let items = try? FileManager.default
            .contentsOfDirectory(atPath: titlesDir.path) else { return nil }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]
        for item in items.sorted() {
            let ext = (item as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                return titlesDir.appendingPathComponent(item).path
            }
        }
        return nil
    }


    nonisolated private static func findGameRoot(in dir: URL) throws -> URL {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])

        let meaningful = items.filter { $0.lastPathComponent != "__MACOSX" }

        if meaningful.count == 1,
           let single = meaningful.first,
           (try? single.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return single
        }
        return dir
    }

    private func ensureGamesDirectory() {
        if !fm.fileExists(atPath: GameContainer.rootURL.path) {
            try? fm.createDirectory(at: GameContainer.rootURL, withIntermediateDirectories: true)
        }
        // Belt-and-suspenders: even though every container also
        // gets its own `isExcludedFromBackup` flag, marking the
        // root directory ensures iOS skips it entirely if it scans
        // top-down before reaching the children. iOS treats the
        // attribute as inheriting to contents per the URL resource
        // docs, so this single set covers anything inside Games/.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = GameContainer.rootURL
        try? rootURL.setResourceValues(values)

        // Sweep existing containers in case they predate this
        // exclusion (or were created before `ensureSubdirs()` set
        // the flag). One-shot per app launch; cheap because the
        // setter is a no-op when the flag is already set.
        for container in GameContainer.discover() {
            container.excludeFromBackup()
        }
    }
}
