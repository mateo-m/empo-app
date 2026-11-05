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

    private static let extensions = ["sf2", "dls"]
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
    /// "sfbk" or "DLS ". The engine's FluidSynth has no libsndfile, so it
    /// can't read SoundFont 3, which has 3 as the major version in `ifil`.
    private static func isSoundSet(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 34), header.count >= 12,
            header.subdata(in: 0..<4) == Data("RIFF".utf8)
        else { return false }
        // A copy that stopped early is shorter than the size in its RIFF header.
        let riffSize = header.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard let fileSize = try? handle.seekToEnd(), UInt64(UInt32(littleEndian: riffSize)) + 8 <= fileSize
        else { return false }
        let form = header.subdata(in: 8..<12)
        if form == Data("DLS ".utf8) { return true }
        // A SoundFont starts with the LIST INFO chunk, and `ifil` comes first in it.
        return form == Data("sfbk".utf8) && header.count == 34
            && header.subdata(in: 24..<28) == Data("ifil".utf8) && header[32] == 2
    }
}
