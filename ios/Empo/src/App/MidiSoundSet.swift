// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// The sound set folders that an import copies into now, and the import
/// failures that the player did not see yet. A settings sheet can close
/// and open again during the copy, so the sheet can't keep this.
@MainActor @Observable
final class MidiSoundSetCopies {
    static let shared = MidiSoundSetCopies()

    enum Failure: Equatable {
        case notASoundSet
        case copy(String)
    }

    private(set) var folders: Set<URL> = []
    var failures: [URL: Failure] = [:]
    private var revisions: [URL: Int] = [:]

    func isCopying(into soundSet: MidiSoundSet) -> Bool {
        folders.contains(soundSet.folderURL)
    }

    /// A copy can start and end between two updates of a view, so
    /// `isCopying` can look unchanged. This count changes at each end of a
    /// copy and at each removal, also when another window did it.
    func revision(of soundSet: MidiSoundSet) -> Int {
        revisions[soundSet.folderURL, default: 0]
    }

    func begin(_ soundSet: MidiSoundSet) {
        folders.insert(soundSet.folderURL)
    }

    func end(_ soundSet: MidiSoundSet, failure: Failure? = nil) {
        failures[soundSet.folderURL] = failure
        folders.remove(soundSet.folderURL)
        revisions[soundSet.folderURL, default: 0] += 1
    }

    func removed(_ soundSet: MidiSoundSet) {
        revisions[soundSet.folderURL, default: 0] += 1
    }
}

/// The sound set that the player imported for MIDI music, for the whole
/// app or for one game. Without one, the engine uses the sound set it ships.
struct MidiSoundSet {
    enum ImportError: Error {
        case notASoundSet
    }

    static let app = MidiSoundSet(
        folderURL: DataDirectory.documentsRootURL.appendingPathComponent("SoundFonts", isDirectory: true))

    static func game(_ container: GameContainer) -> MidiSoundSet {
        MidiSoundSet(
            folderURL: container.empoStateURL.appendingPathComponent("SoundFonts", isDirectory: true))
    }

    /// The file name of the sound set that the engine ships.
    static let builtInName: String? = {
        guard
            let framework = Bundle.main.privateFrameworksURL.flatMap({
                Bundle(url: $0.appendingPathComponent("MkxpCore.framework"))
            }),
            let folder = framework.url(
                forResource: "SoundFonts", withExtension: nil, subdirectory: "Assets.bundle")
        else { return nil }
        return MidiSoundSet(folderURL: folder).current?.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
    }()

    let folderURL: URL

    private static let extensions = ["sf2", "dls"]
    static let contentTypes = extensions.compactMap { UTType(filenameExtension: $0) }

    var current: URL? {
        files.first
    }

    func replace(with source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard Self.isSoundSet(source) else { throw ImportError.notASoundSet }
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

    func removeImported() throws {
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    private var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// SoundFont and DLS files are RIFF files with the form type
    /// "sfbk" or "DLS ". The engine's FluidSynth has no libsndfile, so it
    /// can't read SoundFont 3, which has 3 as the major version in `ifil`.
    /// Apple's sampler loads SoundFont 3 files, so it can't catch them.
    private static func isSoundSet(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 34), header.count >= 12,
            header.subdata(in: 0..<4) == Data("RIFF".utf8)
        else { return false }
        let form = header.subdata(in: 8..<12)
        // A SoundFont starts with the LIST INFO chunk, and `ifil` comes first in it.
        let isSoundFont2 =
            form == Data("sfbk".utf8) && header.count == 34
            && header.subdata(in: 24..<28) == Data("ifil".utf8) && header[32] == 2
        return (isSoundFont2 || form == Data("DLS ".utf8)) && loads(url)
    }

    /// Apple's sampler refuses a file that stopped early or has broken
    /// chunks, also when its header is intact. For a file that it reads but
    /// that has no program 0 in the melodic bank, it throws
    /// `kAudioUnitErr_InvalidPropertyValue`, and the file is good.
    private static func loads(_ url: URL) -> Bool {
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        do {
            try sampler.loadSoundBankInstrument(
                at: url, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            return true
        } catch {
            return (error as NSError).code == Int(kAudioUnitErr_InvalidPropertyValue)
        }
    }
}
