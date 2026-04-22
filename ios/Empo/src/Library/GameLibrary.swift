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
    /// import inside the existing grid/list. Path is empty because
    /// nothing is on disk yet; `progress: 0` renders as the
    /// indeterminate spinner inside `GameStatusIndicator`, which is
    /// the right visual read for the pre-flight validation phase.
    var syntheticEntry: GameEntry {
        GameEntry(
            id: id,
            path: "",
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

    nonisolated static let gamesDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Games", isDirectory: true)

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
        Task.detached {
            let scanned = GameLibrary.scanGames(in: GameLibrary.gamesDirectory, cleanupInvalid: cleanupInvalid)
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
                if initialLoad {
                    lib.syncMetadata()
                }
            }
        }
    }

    /// Scans the games directory. If `cleanupInvalid` is true,
    /// invalid folders are removed instead of kept as entries.
    nonisolated private static func scanGames(
        in gamesDir: URL,
        fm: FileManager = .default,
        cleanupInvalid: Bool
    ) -> [GameEntry] {
        var entries: [GameEntry] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: gamesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let isValid = (try? GameImportValidator.validate(url)) != nil

            if !isValid {
                if cleanupInvalid {
                    NSLog("[GameLibrary] Removing invalid game folder: %@", url.lastPathComponent)
                    try? fm.removeItem(at: url)
                    continue
                }
                // Include as invalid entry so the user can see it
                if var entry = buildGameEntry(from: url, fm: fm) {
                    entry.status = .invalid
                    entries.append(entry)
                }
                continue
            }

            if let entry = buildGameEntry(from: url, fm: fm) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    nonisolated private static func buildGameEntry(from url: URL, fm: FileManager = .default) -> GameEntry? {

        let folderName = url.lastPathComponent
        let iniTitle = GameEntry.parseINITitle(at: url) ?? "Unknown Game"
        let defaultArtwork = findArtwork(at: url)

        // Import writes the UUID as the first 36 chars of the folder
        // name. The game's id is just that UUID.
        let id = String(folderName.prefix(36))

        let metadata = GameMetadata.load(for: id)
        let title = metadata.customTitle ?? iniTitle
        let artworkPath = metadata.customArtworkPath(for: id) ?? defaultArtwork
        let originalTitle = metadata.customTitle != nil ? iniTitle : nil

        return GameEntry(
            id: id,
            path: url.path,
            title: title,
            artworkPath: artworkPath,
            originalTitle: originalTitle,
            lastPlayed: metadata.lastPlayed
        )
    }


    func refreshGameEntry(id: String) {
        guard let idx = games.firstIndex(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: games[idx].path)
        guard var entry = Self.buildGameEntry(from: url) else { return }
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
        // pre-flight passes we commit a progress card to `games` and
        // extraction/finalisation runs with the card visible.
        pendingImports[importID] = PendingImport(id: importID, sourceName: sourceName)

        Task.detached(priority: .userInitiated) {
            defer { self.clearCancellation(importID) }
            do {
                if archiveFormat != nil {
                    try self.importArchive(from: sourceURL, importID: importID, sourceName: sourceName)
                } else {
                    try self.importFolder(from: sourceURL, importID: importID, sourceName: sourceName)
                }
                await MainActor.run {
                    GameLibrary.shared.reload()
                    completion(nil)
                }
            } catch is ImportCancelled {
                NSLog("[GameLibrary] Import cancelled: %@", importID)
                await MainActor.run {
                    _ = GameLibrary.shared.pendingImports.removeValue(forKey: importID)
                    GameLibrary.shared.games.removeAll { $0.id == importID }
                }
            } catch {
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
    nonisolated private func commitPendingToCard(_ importID: String, title: String, artworkPath: String?) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            withAnimation {
                _ = lib.pendingImports.removeValue(forKey: importID)
                lib.games.append(GameEntry(
                    id: importID,
                    path: "",
                    title: title,
                    artworkPath: artworkPath,
                    status: .importing(progress: 0)
                ))
            }
        }
    }

    /// Swap in the card's artwork mid-extract, once the archive
    /// has yielded a `Graphics/Titles/*` image. Called more than
    /// once per import: each time the extractor finds an
    /// alphabetically-smaller candidate the card updates to
    /// match, mirroring the rule used by `findArtwork` after the
    /// full extract completes so the card doesn't flicker to a
    /// different artwork when the import finishes. Rebuilding the
    /// entry (rather than mutating `artworkPath` on the existing
    /// one) goes through SwiftUI's normal diffing so the card
    /// cross-fades the placeholder to the real artwork.
    nonisolated private func updateCardArtwork(_ importID: String, artworkPath: String) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            guard lib.games[idx].artworkPath != artworkPath else { return }
            withAnimation {
                lib.games[idx] = GameEntry(
                    id: importID,
                    path: lib.games[idx].path,
                    title: lib.games[idx].title,
                    artworkPath: artworkPath,
                    originalTitle: lib.games[idx].originalTitle,
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

    nonisolated private func destinationURL(for importID: String, title: String?) -> URL {
        let slug = title.map { GameLibrary.slugify($0) } ?? ""
        let folderName = slug.isEmpty ? importID : "\(importID)-\(slug)"
        return Self.gamesDirectory.appendingPathComponent(folderName)
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
        let artworkPath = Self.findArtwork(at: tmpDest)
        if let path = artworkPath {
            // Warm the decode cache before `tmpDest`'s defer-backed
            // cleanup kicks in so the card keeps rendering the
            // artwork across the move-then-reload window.
            _ = ImageCache.shared.image(for: path)
        }
        commitPendingToCard(importID, title: title, artworkPath: artworkPath)

        // Folder imports don't have a meaningful extraction-progress
        // phase (the heavy copy already happened in the pre-flight).
        // Jump directly to the move; if the card gets cancelled in
        // the brief window before the move finishes, the cancel
        // path below cleans up.
        updateCardProgress(importID, 1.0)

        let destURL = destinationURL(for: importID, title: title)
        try fm.moveItem(at: tmpDest, to: destURL)

        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(at: destURL)
            }
        }

        if isImportCancelled(importID) { throw ImportCancelled() }
        GameLibrary.createMetadata(for: importID)
        committed = true
    }

    nonisolated private func importArchive(from sourceURL: URL, importID: String, sourceName: String) throws {
        let fm = FileManager.default

        // Pre-flight scratch: throwaway dir where we selectively
        // extract just the validation files. Lives only for the
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

        // Pre-flight passed - pick up the title we learned from
        // the extracted `.ini` so the committed card shows the
        // real name while the rest of the archive extracts in the
        // background. Artwork fills in mid-extract via the
        // extract() callback below.
        let title = GameEntry.parseINITitle(at: preflightRoot) ?? sourceName
        commitPendingToCard(importID, title: title, artworkPath: nil)

        // Full extraction now runs visibly - progress feeds the
        // committed card's `.importing(progress:)` status.
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Mid-extract artwork surfacing. Two sources are mirrored
        // against the post-reload `findArtwork` rule:
        //   1. The `.exe` icon (preferred). Only executables that
        //      import `rgss*.dll` qualify - patchers, updaters,
        //      and installer binaries sitting next to the game
        //      (e.g. Pokemon Uranium's `Patcher.exe`) get skipped
        //      wholesale. `Game.exe` is the canonical RPG Maker
        //      binary and wins outright when present; other
        //      qualifying `.exe`s set a tentative sidecar that
        //      `Game.exe` can still overwrite if it arrives
        //      later in archive order.
        //   2. Alphabetically-smallest `Graphics/Titles/*` image
        //      (fallback). Only used when no qualifying
        //      executable has landed yet - once one does,
        //      subsequent Titles updates are ignored because the
        //      card would flicker when post-reload `findArtwork`
        //      picks the exe sidecar over the title image.
        //
        // Both hooks rebuild the committed `GameEntry` through
        // `updateCardArtwork`, so the card cross-fades as the
        // better source lands.
        let exeArtworkLocked = Mutex(false)
        let hasTentativeExeArtwork = Mutex(false)
        let bestTitlesFilename = Mutex<String?>(nil)
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

                    // `.exe` branch - only consider root-level
                    // executables (depth 0 or 1, matching the
                    // archive's optional wrapper folder).
                    if lower.hasSuffix(".exe") {
                        let components = lower.split(separator: "/", omittingEmptySubsequences: false)
                        let depth = components.count - 1
                        guard depth <= 1 else { return }
                        if exeArtworkLocked.withLock({ $0 }) { return }

                        let isGameExe = filename.lowercased() == "game.exe"
                        // Skip utility binaries (patchers,
                        // updaters, launchers, etc.) outright.
                        // `Game.exe` bypasses this check because
                        // it's the canonical RPG Maker default.
                        if !isGameExe, ExecutableIconExtractor.isUtilityExecutable(filename: filename) {
                            return
                        }
                        // Non-canonical binaries defer to any
                        // previously-written tentative sidecar:
                        // only `Game.exe` can still overwrite
                        // because it's the rule winner at
                        // post-reload scan time. Accepting a
                        // second non-`Game.exe` here would cause
                        // a flicker when the library rescan
                        // later picks a different one.
                        if !isGameExe, hasTentativeExeArtwork.withLock({ $0 }) { return }

                        guard let data = try? Data(contentsOf: diskURL, options: .mappedIfSafe) else {
                            return
                        }
                        guard let pe = PEImage(data: data),
                              let image = pe.extractIcon(),
                              let png = image.pngData() else {
                            return
                        }

                        let parent = diskURL.deletingLastPathComponent()
                        let sidecarURL = parent.appendingPathComponent(ExecutableIconExtractor.sidecarFilename)
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
                            // Canonical binary - no further .exe
                            // needs to be inspected.
                            exeArtworkLocked.withLock { $0 = true }
                        }
                        self.updateCardArtwork(importID, artworkPath: sidecarURL.path)
                        return
                    }

                    // Titles fallback - skip once an RGSS exe
                    // icon has landed (the card would flicker
                    // when post-reload findArtwork picks the exe
                    // sidecar over the title image).
                    guard !hasTentativeExeArtwork.withLock({ $0 }) else { return }
                    guard lower.contains("graphics/titles/") else { return }
                    let ext = (relative as NSString).pathExtension.lowercased()
                    guard ["png", "jpg", "jpeg", "bmp"].contains(ext) else { return }

                    let shouldUpdate = bestTitlesFilename.withLock { best -> Bool in
                        if let current = best, current <= filename { return false }
                        best = filename
                        return true
                    }
                    guard shouldUpdate else { return }

                    // The file is at `diskURL` right now, but
                    // `tmpDir` will be swept after the full
                    // extract+move completes. Warm the decode
                    // cache at that path so the card renders the
                    // cached UIImage even after the file moves
                    // (the NSCache entry survives; the subsequent
                    // reload() points the card at the permanent
                    // `destURL/Graphics/Titles/*` and reads fresh
                    // from there).
                    _ = ImageCache.shared.image(for: diskURL.path)
                    self.updateCardArtwork(importID, artworkPath: diskURL.path)
                }
            )
        } catch ArchiveExtractor.Error.cancelled {
            throw ImportCancelled()
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try GameLibrary.findGameRoot(in: tmpDir)
        let destURL = destinationURL(for: importID, title: title)
        try fm.moveItem(at: gameRoot, to: destURL)

        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(at: destURL)
            }
        }

        if isImportCancelled(importID) { throw ImportCancelled() }
        GameLibrary.createMetadata(for: importID)
        committed = true
    }

    nonisolated private static func createMetadata(for gameId: String) {
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.save(for: gameId)
    }


    func deleteGame(_ entry: GameEntry, onError: (@MainActor @Sendable (String) -> Void)? = nil) {
        let wasImporting = entry.isImporting

        if let artworkPath = entry.artworkPath {
            ImageCache.shared.evict(path: artworkPath)
        }

        GameMetadata.delete(for: entry.id)

        withAnimation {
            games.removeAll { $0.id == entry.id }
        }

        if wasImporting {
            cancelImport(entry.id)
            return
        }

        let pathToDelete = entry.path
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                guard fm.fileExists(atPath: pathToDelete) else { return }
                try fm.removeItem(atPath: pathToDelete)
            } catch {
                NSLog("[GameLibrary] Delete error: %@", "\(error)")
                await MainActor.run {
                    GameLibrary.shared.reload()
                    onError?(error.localizedDescription)
                }
            }
        }
    }


    nonisolated private static func findArtwork(at url: URL) -> String? {
        let fm = FileManager.default

        // Prefer the pre-extracted `.exe` icon when available. The
        // sidecar is written once at import time (or lazily
        // on-demand below) and carries the "official" game icon
        // the developer shipped inside the executable. Only fall
        // through to `Graphics/Titles/` when we couldn't produce
        // an icon from the `.exe` (or no `.exe` exists).
        let sidecar = url.appendingPathComponent(ExecutableIconExtractor.sidecarFilename)
        if fm.fileExists(atPath: sidecar.path) {
            return sidecar.path
        }
        if let sidecarPath = ExecutableIconExtractor.writeSidecarIfPossible(in: url) {
            return sidecarPath
        }

        let titlesDir = url.appendingPathComponent("Graphics/Titles")
        guard let items = try? fm.contentsOfDirectory(atPath: titlesDir.path) else { return nil }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]
        for item in items.sorted() {
            let ext = (item as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                return titlesDir.appendingPathComponent(item).path
            }
        }
        return nil
    }


    nonisolated private static func slugify(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = string
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return slug
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
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
        if !fm.fileExists(atPath: Self.gamesDirectory.path) {
            try? fm.createDirectory(at: Self.gamesDirectory, withIntermediateDirectories: true)
        }
    }

    /// Removes orphaned metadata that no longer corresponds to a game on disk.
    private func syncMetadata() {
        let metadataDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Metadata", isDirectory: true)

        guard fm.fileExists(atPath: metadataDir.path),
              let contents = try? fm.contentsOfDirectory(
                  at: metadataDir,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return }

        let gameIDs = Set(games.map(\.id))

        for url in contents {
            let name = url.deletingPathExtension().lastPathComponent
            if !gameIDs.contains(name) {
                NSLog("[GameLibrary] Removing orphaned metadata: %@", url.lastPathComponent)
                try? fm.removeItem(at: url)
            }
        }
    }
}
