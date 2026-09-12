import Foundation

/// A Windows executable packed with Enigma Virtual Box. The packer
/// appends the game's files to the exe as a virtual file system, so
/// the folder next to the exe has no Game.ini, no Data/, no Graphics/.
public struct EnigmaVirtualBox {

    public struct Entry: Equatable, Sendable {
        /// Path inside the container, `/` separated, relative to the exe.
        public let path: String
        public let originalSize: UInt32
        let storedSize: UInt32
        let offset: UInt64

        var isCompressed: Bool { originalSize != storedSize }
    }

    public enum Error: Swift.Error {
        case truncated
        case badEntryName(String)
        case corruptChunk
    }

    public let executableURL: URL
    public let entries: [Entry]

    private static let magic = Data("EVB\0".utf8)
    private static let packedSectionName = ".enigma1"
    private static let rootFolderName = "%DEFAULT FOLDER%"
    private static let fileNode: UInt8 = 2
    private static let folderNode: UInt8 = 3

    /// Nil when the file is not a PE image or holds no Enigma file table.
    public static func open(_ executableURL: URL) -> EnigmaVirtualBox? {
        guard let handle = FileHandle(forReadingAtPath: executableURL.path) else { return nil }
        defer { try? handle.close() }
        guard let section = packedSection(in: handle) else { return nil }
        // The table sits within the first few KB of the section, after
        // the loader's own header.
        let head = read(handle, at: section.offset, count: min(section.size, 1 << 16))
        guard let magicRange = head.range(of: magic) else { return nil }
        let tableStart = section.offset + UInt64(magicRange.lowerBound)
        let tableHeadLength: UInt64 = 64 + 16
        let mainNode = read(handle, at: tableStart + 64, count: 16)
        guard mainNode.count == 16 else { return nil }
        let tableSize = UInt64(mainNode.uint32(at: 0))
        let rootCount = Int(mainNode.uint32(at: 12))
        // The main node's size counts from its own 4th byte to the end
        // of the table. Node records start one byte before its end.
        let table = read(handle, at: tableStart + tableHeadLength - 1, count: Int(tableSize))
        var reader = TableReader(data: table)
        var entries: [Entry] = []
        var dataOffset = tableStart + tableHeadLength + tableSize - 12
        do {
            for _ in 0..<rootCount {
                try readNode(&reader, parent: "", into: &entries, dataOffset: &dataOffset)
            }
        } catch {
            return nil
        }
        return EnigmaVirtualBox(executableURL: executableURL, entries: entries)
    }

    /// Writes the entry to `destination`, creating parent folders.
    public func unpack(_ entry: Entry, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let input = FileHandle(forReadingAtPath: executableURL.path) else {
            throw Error.truncated
        }
        defer { try? input.close() }
        try input.seek(toOffset: entry.offset)
        _ = fm.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw Error.truncated
        }
        defer { try? output.close() }

        if entry.isCompressed {
            try Self.unpackCompressed(entry, from: input, to: output)
        } else {
            try Self.copy(count: Int(entry.storedSize), from: input, to: output)
        }
    }

    // MARK: - Table

    private struct TableReader {
        let data: Data
        var position = 0

        mutating func take(_ count: Int) throws -> Data {
            guard position + count <= data.count else { throw Error.truncated }
            defer { position += count }
            return data.subdata(in: position..<(position + count))
        }

        mutating func uint32() throws -> UInt32 {
            try take(4).uint32(at: 0)
        }

        mutating func uint8() throws -> UInt8 {
            try take(1)[0]
        }

        mutating func utf16Name() throws -> String {
            var bytes = Data()
            while true {
                let unit = try take(2)
                if unit[0] == 0, unit[1] == 0 { break }
                bytes.append(unit)
            }
            guard let name = String(data: bytes, encoding: .utf16LittleEndian) else {
                throw Error.badEntryName(bytes.map { String($0) }.joined(separator: ","))
            }
            return name
        }
    }

    private static func readNode(
        _ reader: inout TableReader,
        parent: String,
        into entries: inout [Entry],
        dataOffset: inout UInt64
    ) throws {
        _ = try reader.uint32()  // node record size
        _ = try reader.take(8)
        let childCount = Int(try reader.uint32())
        let name = try reader.utf16Name()
        let type = try reader.uint8()
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw Error.badEntryName(name)
        }
        switch type {
        case fileNode:
            _ = try reader.take(2)
            let originalSize = try reader.uint32()
            _ = try reader.take(4 + 24 + 15)
            let storedSize = try reader.uint32()
            entries.append(
                Entry(
                    path: parent + name,
                    originalSize: originalSize,
                    storedSize: storedSize,
                    offset: dataOffset
                ))
            dataOffset += UInt64(storedSize)
        case folderNode:
            _ = try reader.take(25)
            let folder = name == rootFolderName ? parent : parent + name + "/"
            for _ in 0..<childCount {
                try readNode(&reader, parent: folder, into: &entries, dataOffset: &dataOffset)
            }
        default:
            throw Error.truncated
        }
    }

    // MARK: - File data

    private static func copy(count: Int, from input: FileHandle, to output: FileHandle) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = input.readData(ofLength: min(remaining, 1 << 20))
            guard !chunk.isEmpty else { throw Error.truncated }
            output.write(chunk)
            remaining -= chunk.count
        }
    }

    /// A compressed entry starts with a block of chunk sizes, then one
    /// aPLib stream per chunk. Each size record is 12 bytes: the
    /// packed size, the running total, padding. The last record may
    /// hold only the packed size.
    private static func unpackCompressed(
        _ entry: Entry, from input: FileHandle, to output: FileHandle
    ) throws {
        let blockHeader = input.readData(ofLength: 8)
        guard blockHeader.count == 8 else { throw Error.truncated }
        let blockSize = Int(blockHeader.uint32(at: 0))
        guard blockSize >= 8 else { throw Error.corruptChunk }
        let sizes = input.readData(ofLength: blockSize - 8)
        guard sizes.count == blockSize - 8 else { throw Error.truncated }
        var chunkSizes: [Int] = []
        var cursor = 0
        while cursor + 4 <= sizes.count {
            chunkSizes.append(Int(sizes.uint32(at: cursor)))
            cursor += 12
        }
        var remaining = Int(entry.storedSize) - blockSize
        var written = 0
        for chunkSize in chunkSizes where remaining > 0 {
            let packed = input.readData(ofLength: min(chunkSize, remaining))
            guard packed.count == min(chunkSize, remaining) else { throw Error.truncated }
            remaining -= packed.count
            let plain = try APLib.decompress(packed)
            output.write(plain)
            written += plain.count
        }
        guard written == Int(entry.originalSize) else { throw Error.corruptChunk }
    }

    // MARK: - PE

    private static func packedSection(in handle: FileHandle) -> (offset: UInt64, size: Int)? {
        let dos = read(handle, at: 0, count: 0x40)
        guard dos.count == 0x40, dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let peOffset = UInt64(dos.uint32(at: 0x3C))
        let pe = read(handle, at: peOffset, count: 24)
        guard pe.count == 24, pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0, pe[3] == 0 else {
            return nil
        }
        let sectionCount = Int(pe.uint16(at: 6))
        let optionalHeaderSize = UInt64(pe.uint16(at: 20))
        let tableOffset = peOffset + 24 + optionalHeaderSize
        let table = read(handle, at: tableOffset, count: sectionCount * 40)
        guard table.count == sectionCount * 40 else { return nil }
        for index in 0..<sectionCount {
            let base = index * 40
            let nameBytes = table.subdata(in: base..<(base + 8)).prefix { $0 != 0 }
            guard String(decoding: nameBytes, as: UTF8.self) == packedSectionName else {
                continue
            }
            let rawSize = Int(table.uint32(at: base + 16))
            let rawOffset = UInt64(table.uint32(at: base + 20))
            return (rawOffset, rawSize)
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data {
        guard (try? handle.seek(toOffset: offset)) != nil else { return Data() }
        return handle.readData(ofLength: count)
    }
}

extension Data {
    fileprivate func uint32(at index: Int) -> UInt32 {
        let base = startIndex + index
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    fileprivate func uint16(at index: Int) -> UInt16 {
        let base = startIndex + index
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }
}
