// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Copies an RPG Maker RTP out of the official installer, or out of an
/// RTP folder from a Windows PC, without running anything from it.
public enum RTPImport {
    public enum Failure: Error, Equatable, Sendable {
        case notRPGMakerFiles
        /// The VX Ace installer keeps its files in `Setup-1.bin`, next
        /// to `Setup.exe`.
        case missingDataFile
        case damaged
    }

    /// The largest RTP, VX Ace, is about 200 MB. More comes only from a
    /// file that is not an RTP.
    public static let maximumSize = 1 << 30

    private static let folders = ["audio", "graphics", "fonts"]
    private static let languages: Set<String> = ["en", "english"]

    /// Files can put an empty folder or a file where a copy goes.
    public static func isCopy(at folder: URL) -> Bool {
        let media = FileManager.default.subdirectoryNames(at: folder)
            .filter { ["audio", "graphics"].contains($0.lowercased()) }
        return Set(media.map { $0.lowercased() }).count == 2
            && media.allSatisfy { holdsFile(folder.appendingPathComponent($0, isDirectory: true)) }
    }

    private static func holdsFile(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return false }
        return enumerator.contains { path in
            guard let path = path as? String else { return false }
            return !folder.appendingPathComponent(path).isDirectory
        }
    }

    /// Reads the RTP in `source`, a folder or an installer, and writes
    /// its Audio, Graphics and Fonts folders into `destination`.
    public static func copy(from source: URL, to destination: URL) throws -> RTPPackage {
        guard source.isDirectory else { return try extract(installer: source, to: destination) }
        for folder in [source] + source.subdirectories {
            if let package = try copyRTPFolder(folder, to: destination) { return package }
        }
        var failure = Failure.notRPGMakerFiles
        for folder in [source] + source.subdirectories {
            for installer in folder.directoryEntries(matchingExtensions: ["exe"]) {
                do {
                    return try extract(installer: installer, to: destination)
                } catch let error as Failure where error == .notRPGMakerFiles {
                    continue
                } catch let error as Failure {
                    // A damaged installer stops after it wrote some files.
                    try? FileManager.default.removeItem(at: destination)
                    failure = error
                }
            }
        }
        throw failure
    }

    /// Returns nil when `folder` is not an RTP folder. A game folder also
    /// has Audio and Graphics, so a folder with `Game.ini` or `Data` is
    /// not one.
    private static func copyRTPFolder(_ folder: URL, to destination: URL) throws -> RTPPackage? {
        let children = Dictionary(
            folder.subdirectories.map { ($0.lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { a, _ in a })
        guard let graphics = children["graphics"], children["audio"] != nil, children["data"] == nil,
            !folder.directoryEntries(matchingExtensions: ["ini"]).contains(where: {
                $0.lastPathComponent.lowercased() == "game.ini"
            }),
            let package = RTPPackage.detect(
                graphicsFolders: Set(graphics.subdirectories.map(\.lastPathComponent)))
        else { return nil }
        let files = try mediaFiles(in: folders.compactMap { children[$0] })
        for file in files {
            let target = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file.url, to: target)
        }
        return package
    }

    /// The regular files in `sources`, with their paths from the parent
    /// of each source. A link can point anywhere on the device, so links
    /// are left out.
    private static func mediaFiles(in sources: [URL]) throws -> [(url: URL, path: String)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var files: [(url: URL, path: String)] = []
        var total = 0
        for source in sources {
            // The URL walk on Linux ignores `producesRelativePathURLs`.
            guard let enumerator = FileManager.default.enumerator(atPath: source.path) else { continue }
            for case let path as String in enumerator {
                if (path as NSString).lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                let file = source.appendingPathComponent(path)
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                total += values.fileSize ?? 0
                guard total <= maximumSize else { throw Failure.notRPGMakerFiles }
                files.append((file, source.lastPathComponent + "/" + path))
            }
        }
        return files
    }

    private static func extract(installer: URL, to destination: URL) throws -> RTPPackage {
        let archive: InnoSetupArchive
        do {
            archive = try InnoSetupArchive(contentsOf: installer)
        } catch InnoSetupArchive.Failure.missingDataFile {
            throw Failure.missingDataFile
        } catch InnoSetupArchive.Failure.damaged {
            throw Failure.damaged
        } catch is InnoSetupArchive.Failure {
            throw Failure.notRPGMakerFiles
        }

        var byPath: [String: (file: InnoSetupArchive.File, parts: [String])] = [:]
        for file in archive.files {
            guard let parts = mediaPath(file.path) else { continue }
            let key = parts.joined(separator: "/").lowercased()
            if let existing = byPath[key], prefersLanguage(of: existing.file) || !prefersLanguage(of: file) {
                continue
            }
            byPath[key] = (file, parts)
        }
        let graphicsFolders = byPath.values.compactMap { entry in
            entry.parts.count > 2 && entry.parts[0].lowercased() == "graphics" ? entry.parts[1] : nil
        }
        guard byPath.values.contains(where: { $0.parts[0].lowercased() == "audio" }),
            let package = RTPPackage.detect(graphicsFolders: Set(graphicsFolders))
        else { throw Failure.notRPGMakerFiles }
        guard byPath.values.reduce(0, { $0 + archive.size(of: $1.file) }) <= maximumSize else {
            throw Failure.notRPGMakerFiles
        }

        let targets = byPath.values.map { entry in
            (file: entry.file, destination: entry.parts.reduce(destination) { $0.appendingPathComponent($1) })
        }
        do {
            try archive.extract(targets)
        } catch is InnoSetupArchive.Failure {
            throw Failure.damaged
        }
        return package
    }

    /// The parts of an `{app}/Audio/…`, `{app}/Graphics/…` or
    /// `{app}/Fonts/…` path. A part such as `..` comes only from a hostile
    /// installer, so the file is left out.
    static func mediaPath(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2, parts[0].lowercased() == "{app}", folders.contains(parts[1].lowercased()),
            parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return Array(parts.dropFirst())
    }

    private static func prefersLanguage(of file: InnoSetupArchive.File) -> Bool {
        file.languages.isEmpty || file.languages.contains { languages.contains($0.lowercased()) }
    }

}

extension URL {
    fileprivate var isDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Leaves out links, which can point anywhere on the device.
    fileprivate var subdirectories: [URL] {
        FileManager.default.subdirectoryNames(at: self).filter { !$0.hasPrefix(".") }.sorted()
            .map { appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }
}
