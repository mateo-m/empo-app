// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import UniformTypeIdentifiers

/// The sound set that the player imported for MIDI music. Without one,
/// the engine uses the sound set it ships.
enum MidiSoundSet {
    enum ImportError: Error {
        case notASoundSet
    }

    static let folderURL = DataDirectory.documentsRootURL.appendingPathComponent(
        "SoundFonts", isDirectory: true)

    private static let extensions = ["sf2", "sf3", "dls"]
    static let contentTypes = extensions.compactMap { UTType(filenameExtension: $0) }

    static var current: URL? {
        files.first
    }

    static func replace(with source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard isSoundSet(source) else { throw ImportError.notASoundSet }
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let staged = folderURL.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staged)
        do {
            try removeImported()
            try fm.moveItem(at: staged, to: folderURL.appendingPathComponent(source.lastPathComponent))
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    static func removeImported() throws {
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// SoundFont and DLS files are RIFF files with the form type
    /// "sfbk" or "DLS ".
    private static func isSoundSet(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }
        return header.prefix(4) == Data("RIFF".utf8)
            && [Data("sfbk".utf8), Data("DLS ".utf8)].contains(header.suffix(4))
    }
}
