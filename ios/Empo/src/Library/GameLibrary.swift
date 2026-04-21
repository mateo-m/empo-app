import Foundation
import UIKit
import SwiftUI
import Observation
import Synchronization

@MainActor @Observable
class GameLibrary {
    static let shared = GameLibrary()

    var games: [GameEntry] = []

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

    nonisolated private func isImportCancelled(_ id: String) -> Bool {
        cancelledImports.withLock { $0.contains(id) }
    }

    nonisolated private func cancelImport(_ id: String) {
        cancelledImports.withLock { _ = $0.insert(id) }
    }

    nonisolated private func clearCancellation(_ id: String) {
        cancelledImports.withLock { _ = $0.remove(id) }
    }

    func importGame(from sourceURL: URL, completion: @escaping (Error?) -> Void) {
        ensureGamesDirectory()

        let archiveFormat = ArchiveExtractor.Format(extension: sourceURL.pathExtension)
        let importID = UUID().uuidString

        let title: String
        let artwork: String?
        if archiveFormat == nil {
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
                if archiveFormat != nil {
                    try self.importArchive(from: sourceURL, importID: importID)
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

    nonisolated private func importArchive(from sourceURL: URL, importID: String) throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try ArchiveExtractor.extract(archive: sourceURL, to: tmpDir) { _, pct in
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
