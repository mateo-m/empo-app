// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import Observation
import UniformTypeIdentifiers

/// The RPG Maker RTPs that the player added. Each game that names one in
/// `Game.ini` reads the same copy. The RTP licence bars Empo from
/// shipping these files, so the copy stays on this device: iCloud backup
/// skips it, and Empo's own backups never read this folder.
@MainActor @Observable
final class RTPLibrary {
    static let shared = RTPLibrary()

    enum Failure: Equatable {
        case notRPGMakerFiles
        case missingDataFile
        case damaged
        case noSpace
        case copy(String)
    }

    nonisolated static let rootURL = DataDirectory.documentsRootURL.appendingPathComponent(
        "RTP", isDirectory: true)
    nonisolated static let contentTypes: [UTType] = [.zip, .exeArchive, .folder]

    private(set) var installed = RTPLibrary.readInstalled()
    private(set) var isImporting = false

    nonisolated static func folderURL(_ package: RTPPackage) -> URL {
        rootURL.appendingPathComponent(package.rawValue, isDirectory: true)
    }

    nonisolated static func isInstalled(_ package: RTPPackage) -> Bool {
        FileManager.default.fileExists(atPath: folderURL(package).path)
    }

    /// One import or removal runs at a time, so two of them can't swap
    /// the same folder under each other. Returns the first failure.
    func importFiles(from sources: [URL]) async -> Failure? {
        guard !isImporting else { return nil }
        isImporting = true
        var firstFailure: Failure?
        for source in sources {
            do {
                try await Task.detached { try Self.copy(from: source) }.value
            } catch {
                firstFailure = firstFailure ?? Self.failure(for: error)
            }
            installed = Self.readInstalled()
        }
        isImporting = false
        return firstFailure
    }

    private static func failure(for error: Error) -> Failure {
        if error.isOutOfSpace { return .noSpace }
        switch error {
        case RTPImport.Failure.notRPGMakerFiles, ArchiveExtractor.Error.cancelled:
            return .notRPGMakerFiles
        case RTPImport.Failure.missingDataFile: return .missingDataFile
        case ArchiveExtractor.Error.writeFailed: return .noSpace
        case RTPImport.Failure.damaged, is ArchiveExtractor.Error: return .damaged
        default:
            NSLog("[RTP] Import failed: %@", "\(error)")
            return .copy(error.localizedDescription)
        }
    }

    func remove(_ package: RTPPackage) {
        guard !isImporting else { return }
        do {
            try FileManager.default.removeItem(at: Self.folderURL(package))
        } catch {
            NSLog("[RTP] Remove failed: %@", "\(error)")
        }
        installed = Self.readInstalled()
    }

    private nonisolated static func readInstalled() -> Set<RTPPackage> {
        Set(RTPPackage.allCases.filter(isInstalled))
    }

    /// The copy is made next to the final folder and then swapped in, so
    /// a game that starts during the import sees the old copy or the new
    /// one, never a part.
    private nonisolated static func copy(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        // The iOS picker copies the pick into tmp, and the system clears
        // tmp only later. A file that the Mac picker gives is the user's.
        #if os(iOS)
        let tmp = fileManager.temporaryDirectory.resolvingSymlinksInPath().pathComponents
        defer {
            if source.resolvingSymlinksInPath().pathComponents.starts(with: tmp) {
                try? fileManager.removeItem(at: source)
            }
        }
        #endif
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = rootURL
        try root.setResourceValues(values)
        // An import that the system stopped leaves its work folder.
        for name in (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) ?? []
        where name.hasPrefix(".import-") {
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(name))
        }

        let work = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        var rtp = source
        if source.pathExtension.lowercased() == "zip" {
            rtp = work.appendingPathComponent("unpacked", isDirectory: true)
            try ArchiveExtractor.extractSelective(
                archive: source, to: rtp, maximumBytes: RTPImport.maximumSize, include: { _ in true })
        }
        let staged = work.appendingPathComponent("copy", isDirectory: true)
        let package = try RTPImport.copy(from: rtp, to: staged)
        let destination = folderURL(package)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }
}
