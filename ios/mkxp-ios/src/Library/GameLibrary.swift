import Foundation
import UIKit
import SwiftUI
import Observation

@MainActor @Observable
class GameLibrary {
    static let shared = GameLibrary()

    var games: [GameEntry] = []

    private let fm = FileManager.default
    /// Lock-protected set — accessed from both main and background threads.
    nonisolated(unsafe) private var cancelledImports = Set<String>()
    nonisolated(unsafe) private let cancelLock = NSLock()

    static let gamesDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Games", isDirectory: true)

    private init() {
        ensureGamesDirectory()
        let cleanupInvalid = UserDefaults.standard.bool(forKey: "cleanupInvalidGames")
        games = Self.scanGames(in: Self.gamesDirectory, cleanupInvalid: cleanupInvalid)
        syncMetadata()
    }


    func reload() {
        // Scan on background to avoid blocking UI during filesystem I/O
        Task.detached {
            let scanned = GameLibrary.scanGames(in: GameLibrary.gamesDirectory, cleanupInvalid: false)
            let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

            await MainActor.run {
                let lib = GameLibrary.shared
                withAnimation {
                    var updatedIDs = Set<String>()
                    for i in lib.games.indices {
                        let id = lib.games[i].id
                        if let fresh = scannedByID[id] {
                            lib.games[i] = fresh
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

            // Validate once — either scan, cleanup, or mark invalid
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

    /// Builds a GameEntry from a game folder. Loads metadata for custom title/artwork.
    nonisolated private static func buildGameEntry(from url: URL, fm: FileManager = .default) -> GameEntry? {

        let folderName = url.lastPathComponent
        let iniTitle = GameEntry.parseINITitle(at: url) ?? "Unknown Game"
        let defaultArtwork = findArtwork(at: url)

        // ID is the UUID prefix (first 36 chars) of the folder name.
        // Legacy folders without a UUID use the full folder name.
        let id: String
        if folderName.count >= 36,
           UUID(uuidString: String(folderName.prefix(36))) != nil {
            id = String(folderName.prefix(36))
        } else {
            id = folderName
        }

        // Load metadata for custom title/artwork overrides
        var metadata = GameMetadata.load(for: id)
        var needsSave = false

        // Set dateAdded retroactively if not present (pre-existing game)
        if metadata.dateAdded == nil {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            metadata.dateAdded = (attrs?[.creationDate] as? Date) ?? Date()
            needsSave = true
        }

        if needsSave {
            metadata.save(for: id)
        }

        // Apply overrides
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


    /// Re-reads a single game entry from disk + metadata for immediate UI feedback.
    func refreshGameEntry(id: String) {
        guard let idx = games.firstIndex(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: games[idx].path)
        guard var entry = Self.buildGameEntry(from: url) else { return }
        entry.status = games[idx].status  // preserve current status
        withAnimation { games[idx] = entry }
    }


    private struct ImportCancelled: Error {}

    nonisolated private func isImportCancelled(_ id: String) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledImports.contains(id)
    }

    nonisolated private func cancelImport(_ id: String) {
        cancelLock.lock()
        cancelledImports.insert(id)
        cancelLock.unlock()
    }

    nonisolated private func clearCancellation(_ id: String) {
        cancelLock.lock()
        cancelledImports.remove(id)
        cancelLock.unlock()
    }

    func importGame(from sourceURL: URL, completion: @escaping (Error?) -> Void) {
        ensureGamesDirectory()

        let isZip = sourceURL.pathExtension.lowercased() == "zip"
        let importID = UUID().uuidString

        // For folders we can read metadata from the source immediately.
        let title: String
        let artwork: String?
        if !isZip {
            title = GameEntry.parseINITitle(at: sourceURL) ?? sourceURL.lastPathComponent
            artwork = Self.findArtwork(at: sourceURL)
        } else {
            title = sourceURL.deletingPathExtension().lastPathComponent
            artwork = nil
        }

        // Skeleton card uses the same ID as the final entry, so SwiftUI
        // animates in-place when reload() provides the real data.
        withAnimation {
            games.append(GameEntry(
                id: importID,
                path: "",
                title: title,
                artworkPath: artwork,
                status: .importing(progress: 0)
            ))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.clearCancellation(importID) }
            do {
                if isZip {
                    try self.importZip(from: sourceURL, importID: importID)
                } else {
                    try self.importFolder(from: sourceURL, importID: importID)
                }
                DispatchQueue.main.async {
                    GameLibrary.shared.reload()
                    completion(nil)
                }
            } catch is ImportCancelled {
                NSLog("[GameLibrary] Import cancelled: %@", importID)
            } catch {
                NSLog("[GameLibrary] Import error: %@", "\(error)")
                DispatchQueue.main.async {
                    withAnimation {
                        GameLibrary.shared.games.removeAll { $0.id == importID }
                    }
                    completion(error)
                }
            }
        }
    }

    nonisolated private func updateProgress(_ importID: String, _ progress: Double) {
        DispatchQueue.main.async {
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            lib.games[idx].status = .importing(progress: progress)
        }
    }

    /// Updates the skeleton card's title and artwork mid-import (e.g. after zip extraction).
    @discardableResult
    nonisolated private func updateSkeleton(_ importID: String, gameDir: URL) -> String? {
        let title = GameEntry.parseINITitle(at: gameDir)
        let artwork = GameLibrary.findArtwork(at: gameDir)
        guard title != nil || artwork != nil else { return title }

        DispatchQueue.main.async {
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            withAnimation {
                lib.games[idx] = GameEntry(
                    id: importID,
                    path: "",
                    title: title ?? lib.games[idx].title,
                    artworkPath: artwork ?? lib.games[idx].artworkPath,
                    status: .importing(progress: lib.games[idx].importProgress)
                )
            }
        }
        return title
    }

    nonisolated private func destinationURL(for importID: String, title: String?) -> URL {
        let slug = title.map { GameLibrary.slugify($0) } ?? ""
        let folderName = slug.isEmpty ? importID : "\(importID)-\(slug)"
        return Self.gamesDirectory.appendingPathComponent(folderName)
    }

    nonisolated private func importFolder(from sourceURL: URL, importID: String) throws {
        let fm = FileManager.default
        let folderName = sourceURL.lastPathComponent

        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tmpDest = tmpDir.appendingPathComponent(folderName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try fm.copyItem(at: sourceURL, to: tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        try GameImportValidator.validate(tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let title = GameEntry.parseINITitle(at: tmpDest)
        let destURL = destinationURL(for: importID, title: title)
        try fm.moveItem(at: tmpDest, to: destURL)

        // If cancelled right after move, clean up the destination
        if isImportCancelled(importID) {
            try? fm.removeItem(at: destURL)
            throw ImportCancelled()
        }

        // Create initial metadata
        GameLibrary.createMetadata(for: importID)
    }

    nonisolated private func importZip(from sourceURL: URL, importID: String) throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try ZipExtractor.extract(zipURL: sourceURL, to: tmpDir) { _, pct in
            self.updateProgress(importID, pct)
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try GameLibrary.findGameRoot(in: tmpDir)
        let title = updateSkeleton(importID, gameDir: gameRoot)
        try GameImportValidator.validate(gameRoot)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let destURL = destinationURL(for: importID, title: title)
        try fm.moveItem(at: gameRoot, to: destURL)

        // If cancelled right after move, clean up the destination
        if isImportCancelled(importID) {
            try? fm.removeItem(at: destURL)
            throw ImportCancelled()
        }

        // Create initial metadata
        GameLibrary.createMetadata(for: importID)
    }

    nonisolated private static func createMetadata(for gameId: String) {
        var metadata = GameMetadata()
        metadata.dateAdded = Date()
        metadata.save(for: gameId)
    }


    func deleteGame(_ entry: GameEntry, onError: ((String) -> Void)? = nil) {
        let wasImporting = entry.isImporting

        // Evict cached artwork
        if let artworkPath = entry.artworkPath {
            ImageCache.shared.evict(path: artworkPath)
        }

        // Remove metadata (JSON + custom media)
        GameMetadata.delete(for: entry.id)

        withAnimation {
            games.removeAll { $0.id == entry.id }
        }

        if wasImporting {
            cancelImport(entry.id)
            return
        }

        let pathToDelete = entry.path
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                guard fm.fileExists(atPath: pathToDelete) else { return }
                try fm.removeItem(atPath: pathToDelete)
            } catch {
                NSLog("[GameLibrary] Delete error: %@", "\(error)")
                DispatchQueue.main.async {
                    GameLibrary.shared.reload()
                    onError?(error.localizedDescription)
                }
            }
        }
    }


    nonisolated private static func findArtwork(at url: URL) -> String? {
        let titlesDir = url.appendingPathComponent("Graphics/Titles")
        let fm = FileManager.default
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


    /// Turns a game title into a filesystem-friendly slug (e.g. "Pokemon Z" → "pokemon-z").
    nonisolated private static func slugify(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = string
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        // Collapse consecutive dashes and trim
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
            // Extract game ID from filename: "{gameId}.json" or directory "{gameId}/"
            let name = url.deletingPathExtension().lastPathComponent
            if !gameIDs.contains(name) {
                NSLog("[GameLibrary] Removing orphaned metadata: %@", url.lastPathComponent)
                try? fm.removeItem(at: url)
            }
        }
    }
}
