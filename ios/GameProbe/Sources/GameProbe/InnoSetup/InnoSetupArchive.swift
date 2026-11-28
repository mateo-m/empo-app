// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.
//
// This file is an altered Swift port of the parts of innoextract
// (https://constexpr.org/innoextract/) that read Inno Setup 5.1.5 to
// 5.4.x. It is not the original software. The innoextract notice:
//
// Copyright (C) 2011-2020 Daniel Scharrer <daniel@constexpr.org>
//
// This software is provided 'as-is', without any express or implied
// warranty.  In no event will the author(s) be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software
//    in a product, an acknowledgment in the product documentation would be
//    appreciated but is not required.
// 2. Altered source versions must be plainly marked as such, and must not be
//    misrepresented as being the original software.
// 3. This notice may not be removed or altered from any source distribution.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Reads the files of an Inno Setup installer without running it.
/// Only data versions 5.1.5 to 5.4.x with LZMA1 or stored chunks are
/// supported, because those are the versions of the RPG Maker RTP
/// installers.
public struct InnoSetupArchive: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notAnInstaller
        case unsupportedVersion(String)
        case damaged
        case missingDataFile(String)
        case unsupportedFile(String)
    }

    public struct File: Sendable, Equatable {
        /// The install path with "/" separators, such as `{app}/Audio/SE/a.ogg`.
        public let path: String
        public let languages: [String]
        let location: Int
    }

    public let files: [File]

    private let entries: [DataEntry]
    private let installer: Data
    private let dataOffset: Int
    private let externalSlice: Data?
    private let version: Int
    private let usesLzma: Bool

    public init(contentsOf url: URL) throws {
        let installer = try Data(contentsOf: url, options: .alwaysMapped)
        let offsets = try Self.readLoaderOffsets(installer)

        var versionReader = InnoByteReader(installer, at: offsets.header)
        let (version, isUnicode) = try Self.readVersion(try versionReader.bytes(64))

        let headerStart = offsets.header + 64
        let (headerBlock, headerBlockEnd) = try Self.readBlock(installer, at: headerStart)
        let (dataBlock, _) = try Self.readBlock(installer, at: headerBlockEnd)

        var header = InnoByteReader(headerBlock)
        let setup = try SetupHeader(&header, version: version, isUnicode: isUnicode)
        try Self.skipEntries(&header, setup: setup, version: version, isUnicode: isUnicode)

        var files: [File] = []
        files.reserveCapacity(setup.fileCount)
        for _ in 0..<setup.fileCount {
            if let file = try Self.readFile(&header, version: version, isUnicode: isUnicode) {
                files.append(file)
            }
        }

        var data = InnoByteReader(dataBlock)
        var entries: [DataEntry] = []
        entries.reserveCapacity(setup.dataEntryCount)
        for _ in 0..<setup.dataEntryCount {
            entries.append(try DataEntry(&data, version: version))
        }
        guard files.allSatisfy({ $0.location < entries.count }) else { throw Failure.damaged }

        if offsets.data == 0 {
            guard setup.slicesPerDisk == 1 else { throw Failure.unsupportedVersion("slices") }
            externalSlice = try Self.openSlice(next: url, baseName: setup.baseFilename)
        } else {
            externalSlice = nil
        }

        switch setup.compression {
        case 0: usesLzma = false
        case 3: usesLzma = true
        default: throw Failure.unsupportedVersion("compression \(setup.compression)")
        }

        self.files = files
        self.entries = entries
        self.installer = installer
        self.dataOffset = offsets.data
        self.version = version
    }

    /// The bytes that `extract` unpacks for `files`. It reads each chunk
    /// from its start to the end of its last chosen file.
    public func unpackedSize(of files: [File]) -> Int {
        Dictionary(grouping: files.map { entries[$0.location] }, by: \.chunk).values.reduce(0) {
            total, chunk in
            total + (chunk.map { $0.fileOffset + $0.fileSize }.max() ?? 0)
        }
    }

    /// Writes each file to its destination URL. Files that share one
    /// stored copy are read once.
    public func extract(_ targets: [(file: File, destination: URL)]) throws {
        let destinations = Dictionary(grouping: targets, by: { $0.file.location })
            .mapValues { $0.map(\.destination) }
        let chunks = Dictionary(grouping: destinations.keys, by: { entries[$0].chunk })
        for (chunk, chunkLocations) in chunks.sorted(by: {
            ($0.key.slice, $0.key.offset) < ($1.key.slice, $1.key.offset)
        }) {
            try Task.checkCancellation()
            let locations = chunkLocations.sorted { entries[$0].fileOffset < entries[$1].fileOffset }
            try extractChunk(chunk, locations: locations, destinations: destinations)
        }
    }

    private func extractChunk(_ chunk: ChunkKey, locations: [Int], destinations: [Int: [URL]]) throws {
        let first = entries[locations[0]]
        for location in locations {
            let entry = entries[location]
            if entry.isEncrypted { throw Failure.unsupportedFile("encrypted") }
            if entry.isCallOptimized { throw Failure.unsupportedFile("call optimized") }
            if entry.lastSlice != entry.chunk.slice { throw Failure.unsupportedFile("spans slices") }
        }
        let slice = externalSlice ?? installer
        let start = (externalSlice == nil ? dataOffset : 0) + chunk.offset
        var reader = InnoByteReader(slice, at: start)
        guard try reader.bytes(4) == Data("zlb\u{1a}".utf8) else { throw Failure.damaged }
        let stored = try reader.bytes(first.chunkSize)

        let read: (UnsafeMutableRawBufferPointer) throws -> Int
        if first.isCompressed {
            guard usesLzma else { throw Failure.unsupportedFile("compression") }
            let decoder = try LzmaRawDecoder(stream: stored)
            read = decoder.read(into:)
        } else {
            var position = stored.startIndex
            read = { output in
                let count = min(output.count, stored.endIndex - position)
                stored.copyBytes(to: output, from: position..<position + count)
                position += count
                return count
            }
        }

        var consumed = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        for location in locations {
            try Task.checkCancellation()
            let entry = entries[location]
            guard entry.fileOffset >= consumed else { throw Failure.damaged }
            try buffer.withUnsafeMutableBytes { raw in
                var skip = entry.fileOffset - consumed
                while skip > 0 {
                    let count = try read(
                        UnsafeMutableRawBufferPointer(rebasing: raw[0..<min(skip, raw.count)]))
                    guard count > 0 else { throw Failure.damaged }
                    skip -= count
                }
            }
            consumed = entry.fileOffset
            try writeFile(entry, to: destinations[location, default: []], buffer: &buffer, read: read)
            consumed += entry.fileSize
        }
    }

    private func writeFile(
        _ entry: DataEntry,
        to destinations: [URL],
        buffer: inout [UInt8],
        read: (UnsafeMutableRawBufferPointer) throws -> Int
    ) throws {
        let fileManager = FileManager.default
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        for destination in destinations {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            handles.append(try FileHandle(forWritingTo: destination))
        }

        var digest = FileDigest(md5: version < 5_03_09)
        var remaining = entry.fileSize
        while remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                let piece = UnsafeMutableRawBufferPointer(rebasing: raw[0..<min(remaining, raw.count)])
                let count = try read(piece)
                digest.update(UnsafeRawBufferPointer(rebasing: piece[0..<count]))
                return count
            }
            guard count > 0 else { throw Failure.damaged }
            let piece = Data(buffer[0..<count])
            for handle in handles { try handle.write(contentsOf: piece) }
            remaining -= count
        }
        guard digest.finalize() == entry.checksum else { throw Failure.damaged }
    }
}

// MARK: - Installer layout

extension InnoSetupArchive {
    private static let loaderMagics = [
        Data("rDlPtS\u{cd}\u{e6}\u{d7}{\u{0b}*".unicodeScalars.map { UInt8($0.value) }),
        Data("nS5W7dT\u{83}\u{aa}\u{1b}\u{0f}j".unicodeScalars.map { UInt8($0.value) }),
    ]

    /// The loader table sits in the RCDATA resource with id 11111.
    private static func readLoaderOffsets(_ installer: Data) throws -> (header: Int, data: Int) {
        let resource = try findLoaderResource(installer)
        var reader = InnoByteReader(installer, at: resource)
        let magic = try reader.bytes(12)
        guard loaderMagics.contains(magic) else { throw Failure.notAnInstaller }
        guard try reader.u32() == 1 else { throw Failure.unsupportedVersion("loader") }
        try reader.skip(4 * 4)
        let header = Int(try reader.u32())
        let data = Int(try reader.u32())
        let checked = installer[(installer.startIndex + resource)..<(installer.startIndex + reader.position)]
        guard try reader.u32() == RawDeflate.crc32(Data(checked)) else { throw Failure.damaged }
        guard header > 0, header < installer.count, data < installer.count else { throw Failure.damaged }
        return (header, data)
    }

    private static func findLoaderResource(_ installer: Data) throws -> Int {
        do {
            var reader = InnoByteReader(installer)
            guard try reader.bytes(2) == Data("MZ".utf8) else { throw Failure.notAnInstaller }
            reader.position = 0x3c
            reader.position = Int(try reader.u32())
            guard try reader.bytes(4) == Data([0x50, 0x45, 0, 0]) else { throw Failure.notAnInstaller }
            try reader.skip(2)
            let sectionCount = Int(try reader.u16())
            try reader.skip(12)
            let optionalSize = Int(try reader.u16())
            try reader.skip(2)
            let optionalStart = reader.position
            switch try reader.u16() {
            case 0x10b: try reader.skip(90)
            case 0x20b: try reader.skip(106)
            default: throw Failure.notAnInstaller
            }
            guard try reader.u32() > 2 else { throw Failure.notAnInstaller }
            try reader.skip(16)
            let resourceRVA = try reader.u32()

            var sections: [(virtualSize: UInt32, virtualAddress: UInt32, rawAddress: UInt32)] = []
            reader.position = optionalStart + optionalSize
            for _ in 0..<sectionCount {
                try reader.skip(8)
                let virtualSize = try reader.u32()
                let virtualAddress = try reader.u32()
                try reader.skip(4)
                let rawAddress = try reader.u32()
                try reader.skip(16)
                sections.append((virtualSize, virtualAddress, rawAddress))
            }
            let toOffset = { (rva: UInt32) throws -> Int in
                guard
                    let section = sections.first(where: {
                        rva >= $0.virtualAddress && rva - $0.virtualAddress < $0.virtualSize
                    })
                else { throw Failure.notAnInstaller }
                return Int(rva - section.virtualAddress) + Int(section.rawAddress)
            }

            let root = try toOffset(resourceRVA)
            let typeDirectory = try findResourceEntry(
                installer, root: root, at: root, id: 10, wantsDirectory: true)
            let nameDirectory = try findResourceEntry(
                installer, root: root, at: typeDirectory, id: 11111, wantsDirectory: true)
            let leaf = try findResourceEntry(
                installer, root: root, at: nameDirectory, id: nil, wantsDirectory: false)
            var leafReader = InnoByteReader(installer, at: leaf)
            return try toOffset(try leafReader.u32())
        } catch Failure.damaged {
            throw Failure.notAnInstaller
        }
    }

    /// Returns the offset of the matching entry's target. A nil id takes
    /// the first entry, which is the first language of a resource.
    private static func findResourceEntry(
        _ installer: Data, root: Int, at directory: Int, id: UInt32?, wantsDirectory: Bool
    ) throws -> Int {
        var reader = InnoByteReader(installer, at: directory + 12)
        let count = Int(try reader.u16()) + Int(try reader.u16())
        for _ in 0..<count {
            let entryID = try reader.u32()
            let target = try reader.u32()
            guard id == nil || entryID == id else { continue }
            let isDirectory = target & 0x8000_0000 != 0
            guard isDirectory == wantsDirectory else { throw Failure.notAnInstaller }
            return root + Int(target & 0x7fff_ffff)
        }
        throw Failure.notAnInstaller
    }

    /// Returns the version as major * 10000 + minor * 100 + patch.
    private static func readVersion(_ raw: Data) throws -> (Int, Bool) {
        let prefix = "Inno Setup Setup Data ("
        guard let text = String(bytes: raw.prefix { $0 != 0 }, encoding: .ascii), text.hasPrefix(prefix),
            let close = text.firstIndex(of: ")")
        else {
            throw Failure.notAnInstaller
        }
        let numbers = text[text.index(text.startIndex, offsetBy: prefix.count)..<close]
        let parts = numbers.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0..<100).contains($0) }) else {
            throw Failure.unsupportedVersion(text)
        }
        let version = parts[0] * 10000 + parts[1] * 100 + parts[2]
        guard (5_01_05..<5_05_00).contains(version) else { throw Failure.unsupportedVersion(String(numbers)) }
        let isUnicode = text[close...].lowercased().contains("(u)")
        return (version, isUnicode)
    }

    /// A block is a CRC-checked size, a compression byte, then 4 KiB
    /// pieces that each carry their own CRC.
    private static func readBlock(_ installer: Data, at start: Int) throws -> (Data, Int) {
        var reader = InnoByteReader(installer, at: start)
        let expected = try reader.u32()
        let sizeAndKind = try reader.bytes(5)
        guard RawDeflate.crc32(Data(sizeAndKind)) == expected else { throw Failure.damaged }
        var sizeReader = InnoByteReader(Data(sizeAndKind))
        let storedSize = Int(try sizeReader.u32())
        let isCompressed = try sizeReader.u8() != 0
        let end = reader.position + storedSize

        var joined = Data()
        while reader.position < end {
            let pieceCRC = try reader.u32()
            let piece = try reader.bytes(min(4096, end - reader.position))
            guard RawDeflate.crc32(Data(piece)) == pieceCRC else { throw Failure.damaged }
            joined.append(piece)
        }
        guard isCompressed else { return (joined, end) }
        return (try LzmaRawDecoder(stream: joined).readAll(limit: 1 << 26), end)
    }

    private static func openSlice(next installer: URL, baseName: String) throws -> Data {
        let folder = installer.deletingLastPathComponent()
        let candidates = [installer.deletingPathExtension().lastPathComponent, baseName]
            .map { "\($0)-1.bin" }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard
            let name = candidates.lazy.compactMap({ candidate in
                names.first { $0 == candidate } ?? names.first { $0.lowercased() == candidate.lowercased() }
            }).first
        else {
            throw Failure.missingDataFile(candidates[0])
        }
        let slice = try Data(contentsOf: folder.appendingPathComponent(name), options: .alwaysMapped)
        var reader = InnoByteReader(slice)
        guard try reader.bytes(8) == Data("idska32\u{1a}".utf8) else { throw Failure.damaged }
        let size = Int(try reader.u32())
        guard size <= slice.count, size >= reader.position else { throw Failure.damaged }
        return slice.prefix(size)
    }
}

// MARK: - Setup header and entries

extension InnoSetupArchive {
    private struct SetupHeader {
        var baseFilename = ""
        var counts: [Int] = []
        var slicesPerDisk = 1
        var compression = 0

        var fileCount: Int { counts[7] }
        var dataEntryCount: Int { counts[8] }

        init(_ reader: inout InnoByteReader, version v: Int, isUnicode: Bool) throws {
            try reader.skipStrings(6)
            if v >= 5_01_13 { try reader.skipStrings(1) }
            try reader.skipStrings(5)
            baseFilename = try InnoSetupArchive.decode(try reader.string(), isUnicode: isUnicode)
            if v < 5_02_05 { try reader.skipStrings(3) }
            try reader.skipStrings(7)
            if v < 5_02_05 { try reader.skipStrings(1) }
            try reader.skipStrings(4)
            if v >= 5_03_08 { try reader.skipStrings(1) }
            if v >= 5_03_10 { try reader.skipStrings(1) }
            if v >= 5_02_05 { try reader.skipStrings(3) }
            if v >= 5_02_01 && v < 5_03_10 { try reader.skipStrings(1) }
            if v >= 5_02_05 { try reader.skipStrings(1) }
            if !isUnicode { try reader.skip(32) }

            // language, message, permission, type, component, task,
            // directory, file, data entry, icon, ini, registry, delete,
            // uninstall delete, run, uninstall run.
            for _ in 0..<16 {
                let count = Int(try reader.u32())
                guard count <= 1_000_000 else { throw Failure.damaged }
                counts.append(count)
            }

            try reader.skip(windowsVersions + 12)
            try reader.skip((v >= 5_03_09 ? 20 : 16) + 8)
            try reader.skip(8)
            slicesPerDisk = Int(try reader.u32())
            try reader.skip(5)
            compression = Int(try reader.u8())
            try reader.skip(2)
            if v >= 5_02_01 && v < 5_03_10 { try reader.skip(8) }
            if v >= 5_03_03 { try reader.skip(2) }
            if v >= 5_03_06 { try reader.skip(4) }

            var flagCount = 39
            if v < 5_03_10 { flagCount += 1 }
            if v < 5_03_03 { flagCount += 2 }
            if v < 5_03_08 { flagCount += 1 }
            if !isUnicode { flagCount += 1 }
            if v >= 5_01_13 { flagCount += 1 }
            if v >= 5_02_01 { flagCount += 1 }
            if v >= 5_03_08 { flagCount += 1 }
            if v >= 5_03_09 { flagCount += 1 }
            try reader.skip(InnoSetupArchive.flagBytes(flagCount))
        }
    }

    private static func skipEntries(
        _ reader: inout InnoByteReader, setup: SetupHeader, version v: Int, isUnicode: Bool
    ) throws {
        for _ in 0..<setup.counts[0] {
            try reader.skipStrings(10)
            try reader.skip(4)
            if !isUnicode || v < 5_03_00 { try reader.skip(4) }
            try reader.skip(16)
            if v >= 5_02_03 { try reader.skip(1) }
        }
        for _ in 0..<setup.counts[1] {
            try reader.skipStrings(2)
            try reader.skip(4)
        }
        for _ in 0..<setup.counts[2] {
            try reader.skipStrings(1)
        }
        for _ in 0..<setup.counts[3] {
            try reader.skipStrings(4)
            try reader.skip(windowsVersions + 1 + 1 + 8)
        }
        for _ in 0..<setup.counts[4] {
            try reader.skipStrings(5)
            try reader.skip(8 + 4 + 1 + windowsVersions + 1 + 8)
        }
        for _ in 0..<setup.counts[5] {
            try reader.skipStrings(6)
            try reader.skip(4 + 1 + windowsVersions + 1)
        }
        for _ in 0..<setup.counts[6] {
            try reader.skipStrings(1 + 6)
            try reader.skip(4 + windowsVersions + 2 + 1)
        }
    }

    /// Returns nil for an entry that copies a file from outside the
    /// installer, because it has no data entry.
    private static func readFile(
        _ reader: inout InnoByteReader, version v: Int, isUnicode: Bool
    ) throws -> File? {
        try reader.skipStrings(1)
        let destination = try decode(try reader.string(), isUnicode: isUnicode)
        try reader.skipStrings(1)
        if v >= 5_02_05 { try reader.skipStrings(1) }
        try reader.skipStrings(2)
        let languages = try decode(try reader.string(), isUnicode: isUnicode)
        try reader.skipStrings(3)
        try reader.skip(windowsVersions)
        let location = try reader.u32()
        try reader.skip(4 + 8 + 2)
        try reader.skip(4)
        try reader.skip(1)
        guard location != UInt32.max else { return nil }
        return File(
            path: destination.replacingOccurrences(of: "\\", with: "/"),
            languages: languages.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init),
            location: Int(location))
    }

    struct ChunkKey: Hashable {
        let slice: Int
        let offset: Int
    }

    struct DataEntry: Sendable {
        let chunk: ChunkKey
        let lastSlice: Int
        let fileOffset: Int
        let fileSize: Int
        let chunkSize: Int
        let checksum: Data
        let isCompressed: Bool
        let isEncrypted: Bool
        let isCallOptimized: Bool

        init(_ reader: inout InnoByteReader, version v: Int) throws {
            let firstSlice = Int(try reader.u32())
            lastSlice = Int(try reader.u32())
            chunk = ChunkKey(slice: firstSlice, offset: Int(try reader.u32()))
            fileOffset = try Self.size(try reader.u64())
            fileSize = try Self.size(try reader.u64())
            chunkSize = try Self.size(try reader.u64())
            checksum = Data(try reader.bytes(v >= 5_03_09 ? 20 : 16))
            try reader.skip(8 + 8)
            let flags = try reader.bytes(InnoSetupArchive.flagBytes(v >= 5_01_13 ? 9 : 8))
            let low = flags[flags.startIndex]
            isCallOptimized = low & (1 << 4) != 0
            isEncrypted = low & (1 << 6) != 0
            isCompressed = low & (1 << 7) != 0
        }

        private static func size(_ value: UInt64) throws -> Int {
            guard value <= UInt64(Int32.max) else { throw Failure.damaged }
            return Int(value)
        }
    }

    /// The lowest and the first unsupported Windows version: a u16
    /// build, a u8 minor and a u8 major for Windows and for NT, then
    /// the NT service pack.
    private static let windowsVersions = 2 * 10

    /// N flags take one bit each. A set of 3 bytes is padded to 4.
    private static func flagBytes(_ count: Int) -> Int {
        let bytes = (count + 7) / 8
        return bytes == 3 ? 4 : bytes
    }

    private static func decode(_ raw: Data, isUnicode: Bool) throws -> String {
        let text =
            isUnicode
            ? String(data: raw, encoding: .utf16LittleEndian)
            : String(data: raw, encoding: .windowsCP1252)
        guard let text else { throw Failure.damaged }
        return text
    }
}

enum FileDigest {
    case md5(Insecure.MD5)
    case sha1(Insecure.SHA1)

    init(md5: Bool) {
        self = md5 ? .md5(Insecure.MD5()) : .sha1(Insecure.SHA1())
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        switch self {
        case .md5(var hash):
            hash.update(bufferPointer: bytes)
            self = .md5(hash)
        case .sha1(var hash):
            hash.update(bufferPointer: bytes)
            self = .sha1(hash)
        }
    }

    func finalize() -> Data {
        switch self {
        case .md5(let hash): Data(hash.finalize())
        case .sha1(let hash): Data(hash.finalize())
        }
    }
}
