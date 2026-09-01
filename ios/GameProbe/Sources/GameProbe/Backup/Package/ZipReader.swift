import Foundation

/// One entry, as the central directory names it.
public struct ZipEntry: Equatable, Sendable {
    public var path: String
    public var uncompressedSize: Int64
    public var compressedSize: Int64
    public var crc: UInt32
    public var isDeflated: Bool
    public var headerOffset: Int64
    /// The Unix mode says a link, so nothing extracts it, per 12.6.
    public var isSymbolicLink: Bool
    public var isDirectory: Bool { path.hasSuffix("/") }
}

/// Reads a ZIP64 file through its central directory, per SPEC 12.6.
///
/// It reads the directory at the end of the file rather than the
/// local headers, so a package another tool rewrote still reads, and
/// a local header that disagrees with the directory never decides
/// anything.
public final class ZipReader {

    public enum Failure: Error, Equatable {
        case notAZip
        case truncated
        case unreadableEntry(String)
        case checksumMismatch(String)
    }

    private let handle: FileHandle
    private let length: Int64
    public private(set) var entries: [ZipEntry] = []

    public init(reading url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.notAZip
        }
        self.handle = handle
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.length = Int64(size)
        do {
            entries = try readTheDirectory()
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    public func close() { try? handle.close() }

    public func entry(at path: String) -> ZipEntry? {
        entries.first { $0.path == path }
    }

    // MARK: - The directory

    private func readTheDirectory() throws -> [ZipEntry] {
        // The end record carries a comment of up to 64 KB, so the
        // search covers that much plus the record itself.
        let window = Int64(min(length, 66 * 1_024))
        guard window >= 22 else { throw Failure.notAZip }
        let tail = read(at: length - window, count: Int(window))
        guard let end = lastIndex(of: 0x0605_4B50, in: tail) else { throw Failure.notAZip }

        var count = Int(tail.u16(end + 10))
        var directoryOffset = Int64(tail.u32(end + 16))
        let locator = lastIndex(of: 0x0706_4B50, in: tail)

        if let locator {
            let record = Int64(bitPattern: tail.u64(locator + 8))
            let head = read(at: record, count: 56)
            guard head.count == 56, head.u32(0) == 0x0606_4B50 else { throw Failure.truncated }
            count = Int(head.u64(32))
            directoryOffset = Int64(bitPattern: head.u64(48))
        }

        var out: [ZipEntry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            let head = read(at: cursor, count: 46)
            guard head.count == 46, head.u32(0) == 0x0201_4B50 else { throw Failure.truncated }

            let nameLength = Int(head.u16(28))
            let extraLength = Int(head.u16(30))
            let commentLength = Int(head.u16(32))
            let fields = read(at: cursor + 46, count: nameLength + extraLength)
            guard fields.count == nameLength + extraLength else { throw Failure.truncated }

            let name = String(decoding: fields.prefix(nameLength), as: UTF8.self)
            var entry = ZipEntry(
                path: name,
                uncompressedSize: Int64(head.u32(24)),
                compressedSize: Int64(head.u32(20)),
                crc: head.u32(16),
                isDeflated: head.u16(10) == 8,
                headerOffset: Int64(head.u32(42)),
                isSymbolicLink: Self.isALink(madeBy: head.u16(4), attributes: head.u32(38)))
            apply(
                zip64: Data(fields.dropFirst(nameLength)), to: &entry,
                base: (head.u32(24), head.u32(20), head.u32(42)))
            out.append(entry)

            cursor += Int64(46 + nameLength + extraLength + commentLength)
        }
        return out
    }

    /// The ZIP64 extra field replaces each 32-bit value that reads
    /// `0xFFFFFFFF`, in the fixed order of the appnote.
    private func apply(
        zip64 extra: Data, to entry: inout ZipEntry, base: (UInt32, UInt32, UInt32)
    ) {
        var index = 0
        while index + 4 <= extra.count {
            let id = extra.u16(index)
            let size = Int(extra.u16(index + 2))
            guard index + 4 + size <= extra.count else { return }
            if id == 0x0001 {
                var field = index + 4
                let unknown: UInt32 = 0xFFFF_FFFF
                if base.0 == unknown, field + 8 <= index + 4 + size {
                    entry.uncompressedSize = Int64(bitPattern: extra.u64(field))
                    field += 8
                }
                if base.1 == unknown, field + 8 <= index + 4 + size {
                    entry.compressedSize = Int64(bitPattern: extra.u64(field))
                    field += 8
                }
                if base.2 == unknown, field + 8 <= index + 4 + size {
                    entry.headerOffset = Int64(bitPattern: extra.u64(field))
                }
                return
            }
            index += 4 + size
        }
    }

    /// The upper byte of "version made by" names the host system,
    /// and 3 is Unix. Only there do the upper 16 bits of the
    /// external attributes hold a file mode.
    private static func isALink(madeBy: UInt16, attributes: UInt32) -> Bool {
        guard madeBy >> 8 == 3 else { return false }
        return (attributes >> 16) & 0xF000 == 0xA000
    }

    // MARK: - Reading one entry

    public func data(of entry: ZipEntry) throws -> Data {
        let body = try readTheBody(of: entry)
        let out = entry.isDeflated ? try inflate(body, entry: entry) : body
        guard RawDeflate.crc32(out) == entry.crc else {
            throw Failure.checksumMismatch(entry.path)
        }
        return out
    }

    /// Writes one entry to a file. A stored entry copies in chunks,
    /// so a multi-gigabyte asset never enters memory.
    public func extract(_ entry: ZipEntry, to url: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil),
            let out = try? FileHandle(forWritingTo: url)
        else {
            throw Failure.unreadableEntry(entry.path)
        }
        defer { try? out.close() }

        if entry.isDeflated {
            // A compressed entry inflates through the stream, which
            // holds one block at a time.
            try inflateToFile(entry, out: out)
            return
        }

        var start = try bodyOffset(of: entry)
        var left = entry.compressedSize
        var crc: UInt32 = 0
        let chunk = Int64(1_024 * 1_024)
        while left > 0 {
            let take = Int(min(chunk, left))
            let bytes = read(at: start, count: take)
            guard bytes.count == take else { throw Failure.truncated }
            crc = RawDeflate.crc32(bytes, seed: crc)
            out.write(bytes)
            start += Int64(take)
            left -= Int64(take)
        }
        guard crc == entry.crc else { throw Failure.checksumMismatch(entry.path) }
    }

    private func inflateToFile(_ entry: ZipEntry, out: FileHandle) throws {
        #if canImport(Compression)
        guard let stream = DeflateStream.decoder() else {
            throw Failure.unreadableEntry(entry.path)
        }
        var start = try bodyOffset(of: entry)
        var left = entry.compressedSize
        var crc: UInt32 = 0
        let chunk = Int64(1_024 * 1_024)
        while left > 0 {
            let take = Int(min(chunk, left))
            let bytes = read(at: start, count: take)
            guard bytes.count == take else { throw Failure.truncated }
            guard let produced = stream.push(bytes) else {
                throw Failure.unreadableEntry(entry.path)
            }
            crc = RawDeflate.crc32(produced, seed: crc)
            out.write(produced)
            start += Int64(take)
            left -= Int64(take)
        }
        guard let tail = stream.finish() else { throw Failure.unreadableEntry(entry.path) }
        crc = RawDeflate.crc32(tail, seed: crc)
        out.write(tail)
        guard crc == entry.crc else { throw Failure.checksumMismatch(entry.path) }
        #else
        try out.write(contentsOf: data(of: entry))
        #endif
    }

    private func inflate(_ body: Data, entry: ZipEntry) throws -> Data {
        #if canImport(Compression)
        guard let stream = DeflateStream.decoder(),
            let head = stream.push(body), let tail = stream.finish()
        else {
            throw Failure.unreadableEntry(entry.path)
        }
        return head + tail
        #else
        guard let out = try? RawDeflate.inflate(body) else {
            throw Failure.unreadableEntry(entry.path)
        }
        return out
        #endif
    }

    private func readTheBody(of entry: ZipEntry) throws -> Data {
        let start = try bodyOffset(of: entry)
        let bytes = read(at: start, count: Int(entry.compressedSize))
        guard bytes.count == Int(entry.compressedSize) else { throw Failure.truncated }
        return bytes
    }

    /// The local header repeats the name and the extra field with
    /// its own lengths, so the body starts past those and not past
    /// the ones the directory carries.
    private func bodyOffset(of entry: ZipEntry) throws -> Int64 {
        let head = read(at: entry.headerOffset, count: 30)
        guard head.count == 30, head.u32(0) == 0x0403_4B50 else { throw Failure.truncated }
        return entry.headerOffset + 30 + Int64(head.u16(26)) + Int64(head.u16(28))
    }

    // MARK: - Bytes

    private func read(at offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        try? handle.seek(toOffset: UInt64(offset))
        return handle.readData(ofLength: count)
    }

    private func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

extension Data {
    func u16(_ index: Int) -> UInt16 {
        let base = startIndex + index
        guard base + 1 < endIndex else { return 0 }
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32(_ index: Int) -> UInt32 {
        let base = startIndex + index
        guard base + 3 < endIndex else { return 0 }
        var value: UInt32 = 0
        for step in 0..<4 { value |= UInt32(self[base + step]) << (8 * step) }
        return value
    }

    func u64(_ index: Int) -> UInt64 {
        let base = startIndex + index
        guard base + 7 < endIndex else { return 0 }
        var value: UInt64 = 0
        for step in 0..<8 { value |= UInt64(self[base + step]) << (8 * step) }
        return value
    }
}
