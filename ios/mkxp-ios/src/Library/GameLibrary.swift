import Foundation
import UIKit
import SwiftUI
import Observation

@Observable
class GameLibrary {
    static let shared = GameLibrary()

    var games: [GameEntry] = []

    private let fm = FileManager.default
    private var cancelledImports = Set<String>()
    private let cancelLock = NSLock()

    var gamesDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Games", isDirectory: true)
    }

    private init() {
        ensureGamesDirectory()
        if AppSettings.shared.cleanupInvalidGames {
            removeInvalidGameFolders()
        }
        games = scanGames()
    }

    // MARK: - Scan

    /// Removes game folders that fail validation (e.g. half-imported due to crash).
    private func removeInvalidGameFolders() {
        guard let contents = try? fm.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            if (try? GameImportValidator.validate(url)) == nil {
                NSLog("[GameLibrary] Removing invalid game folder: %@", url.lastPathComponent)
                try? fm.removeItem(at: url)
            }
        }
    }

    func reload() {
        let scanned = scanGames()
        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        DispatchQueue.main.async {
            withAnimation {
                // Update existing entries in-place (skeleton -> real, or metadata refresh)
                var updatedIDs = Set<String>()
                for i in self.games.indices {
                    let id = self.games[i].id
                    if let fresh = scannedByID[id] {
                        self.games[i] = fresh
                        updatedIDs.insert(id)
                    }
                }

                // Remove entries that are no longer on disk and not importing
                self.games.removeAll { !$0.isImporting && !scannedByID.keys.contains($0.id) }

                // Append any new games not already in the list
                for entry in scanned where !updatedIDs.contains(entry.id) {
                    self.games.append(entry)
                }
            }
        }
    }

    private func scanGames() -> [GameEntry] {
        var entries: [GameEntry] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            if let entry = scanGameFolder(url) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return entries
    }

    private func scanGameFolder(_ url: URL) -> GameEntry? {
        guard (try? GameImportValidator.validate(url)) != nil else { return nil }

        let folderName = url.lastPathComponent
        let title = parseGameTitle(at: url) ?? "Unknown Game"
        let artwork = findArtwork(at: url)

        // ID is the UUID prefix (first 36 chars) of the folder name.
        // Legacy folders without a UUID use the full folder name.
        let id: String
        if folderName.count >= 36,
           UUID(uuidString: String(folderName.prefix(36))) != nil {
            id = String(folderName.prefix(36))
        } else {
            id = folderName
        }

        return GameEntry(
            id: id,
            path: url.path,
            title: title,
            artworkPath: artwork
        )
    }

    // MARK: - Import

    private struct ImportCancelled: Error {}

    private func isImportCancelled(_ id: String) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledImports.contains(id)
    }

    private func cancelImport(_ id: String) {
        cancelLock.lock()
        cancelledImports.insert(id)
        cancelLock.unlock()
    }

    private func clearCancellation(_ id: String) {
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
            title = parseGameTitle(at: sourceURL) ?? sourceURL.lastPathComponent
            artwork = findArtwork(at: sourceURL)
        } else {
            title = sourceURL.deletingPathExtension().lastPathComponent
            artwork = nil
        }

        // Add skeleton card immediately — same ID as final entry, so SwiftUI
        // updates in-place when reload() provides the real data.
        withAnimation {
            games.append(GameEntry(
                id: importID,
                path: "",
                title: title,
                artworkPath: artwork,
                isImporting: true
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
                self.reload()
                DispatchQueue.main.async { completion(nil) }
            } catch is ImportCancelled {
                NSLog("[GameLibrary] Import cancelled: %@", importID)
            } catch {
                NSLog("[GameLibrary] Import error: %@", "\(error)")
                DispatchQueue.main.async {
                    withAnimation {
                        self.games.removeAll { $0.id == importID }
                    }
                    completion(error)
                }
            }
        }
    }

    /// Updates the skeleton card's import progress (0.0–1.0).
    private func updateProgress(_ importID: String, _ progress: Double) {
        DispatchQueue.main.async {
            guard let idx = self.games.firstIndex(where: { $0.id == importID }) else { return }
            self.games[idx].importProgress = progress
        }
    }

    /// Updates the skeleton card's title and artwork mid-import (e.g. after zip extraction).
    private func updateSkeleton(_ importID: String, gameDir: URL) {
        let title = parseGameTitle(at: gameDir)
        let artwork = findArtwork(at: gameDir)
        guard title != nil || artwork != nil else { return }

        DispatchQueue.main.async {
            guard let idx = self.games.firstIndex(where: { $0.id == importID }) else { return }
            withAnimation {
                self.games[idx] = GameEntry(
                    id: importID,
                    path: "",
                    title: title ?? self.games[idx].title,
                    artworkPath: artwork ?? self.games[idx].artworkPath,
                    isImporting: true
                )
            }
        }
    }

    private func destinationURL(for importID: String, gameDir: URL) -> URL {
        let title = parseGameTitle(at: gameDir)
        let slug = title.map { slugify($0) } ?? ""
        let folderName = slug.isEmpty ? importID : "\(importID)-\(slug)"
        return gamesDirectory.appendingPathComponent(folderName)
    }

    private func importFolder(from sourceURL: URL, importID: String) throws {
        let folderName = sourceURL.lastPathComponent

        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tmpDest = tmpDir.appendingPathComponent(folderName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try fm.copyItem(at: sourceURL, to: tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        try GameImportValidator.validate(tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let destURL = destinationURL(for: importID, gameDir: tmpDest)
        try fm.moveItem(at: tmpDest, to: destURL)

        // If cancelled right after move, clean up the destination
        if isImportCancelled(importID) {
            try? fm.removeItem(at: destURL)
            throw ImportCancelled()
        }
    }

    private func importZip(from sourceURL: URL, importID: String) throws {
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try ZipExtractor.extract(zipURL: sourceURL, to: tmpDir) { _, pct in
            self.updateProgress(importID, pct)
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try findGameRoot(in: tmpDir)
        updateSkeleton(importID, gameDir: gameRoot)
        try GameImportValidator.validate(gameRoot)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let destURL = destinationURL(for: importID, gameDir: gameRoot)
        try fm.moveItem(at: gameRoot, to: destURL)

        // If cancelled right after move, clean up the destination
        if isImportCancelled(importID) {
            try? fm.removeItem(at: destURL)
            throw ImportCancelled()
        }
    }

    // MARK: - Delete

    func deleteGame(_ entry: GameEntry, onError: ((String) -> Void)? = nil) {
        let wasImporting = entry.isImporting

        // Evict cached artwork
        if let artworkPath = entry.artworkPath {
            ImageCache.shared.evict(path: artworkPath)
        }

        withAnimation {
            games.removeAll { $0.id == entry.id }
        }

        if wasImporting {
            cancelImport(entry.id)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.fm.removeItem(atPath: entry.path)
            } catch {
                NSLog("[GameLibrary] Delete error: %@", "\(error)")
                DispatchQueue.main.async {
                    self.reload()
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Metadata Helpers

    private func parseGameTitle(at url: URL) -> String? {
        let iniURL: URL? = {
            let gameIni = url.appendingPathComponent("Game.ini")
            if fm.fileExists(atPath: gameIni.path) { return gameIni }
            if let items = try? fm.contentsOfDirectory(atPath: url.path) {
                for item in items where item.lowercased().hasSuffix(".ini") {
                    return url.appendingPathComponent(item)
                }
            }
            return nil
        }()
        guard let iniURL, let data = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return nil
        }

        var inGameSection = false
        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inGameSection = trimmed.lowercased().hasPrefix("[game]")
                continue
            }
            if inGameSection && trimmed.lowercased().hasPrefix("title=") {
                let value = String(trimmed.dropFirst("title=".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func findArtwork(at url: URL) -> String? {
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

    // MARK: - Private Helpers

    /// Turns a game title into a filesystem-friendly slug (e.g. "Pokemon Z" → "pokemon-z").
    private func slugify(_ string: String) -> String {
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

    private func findGameRoot(in dir: URL) throws -> URL {
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
        if !fm.fileExists(atPath: gamesDirectory.path) {
            try? fm.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        }
    }
}
