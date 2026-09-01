import Foundation

public enum ZipFailure: Error, Equatable {
    case cannotCreate(String)
    case cannotRead(String)
    case writeFailed(String)
    case compressionFailed(String)
    case duplicatePath(String)
}

/// Writes a ZIP64 file, one entry at a time, per SPEC 12.1.
///
/// Every entry streams: the writer reads the source in chunks, so a
/// 4 GB game asset never enters memory. The local header carries the
/// ZIP64 extra field with both sizes, and the writer seeks back to
/// fill in the CRC and the sizes once the entry ends. The central
/// directory then names only the fields that pass the 32-bit limit,
/// which is what the appnote asks for.
///
/// ZIP64 is not optional here. A whole-library export of several
/// multi-gigabyte games passes both 4 GiB limits of plain ZIP.
public final class ZipWriter {

    /// What one written entry became.
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var uncompressedSize: Int64
        public var compressedSize: Int64
        public var crc: UInt32
        public var isDeflated: Bool
        public var offset: Int64
        public var modifiedAt: Date
    }

    private let handle: FileHandle
    private let url: URL
    private var entries: [Entry] = []
    private var paths: Set<String> = []
    private var offset: Int64 = 0
    private let chunkSize = 1_024 * 1_024

    public init(creating url: URL) throws(ZipFailure) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: url)
        else {
            throw ZipFailure.cannotCreate(url.lastPathComponent)
        }
        self.handle = handle
    }

    // MARK: - Entries

    @discardableResult
    public func add(
        data: Data, at path: String, modifiedAt: Date = Date()
    ) throws(ZipFailure)
        -> Entry
    {
        try add(path: path, size: Int64(data.count), modifiedAt: modifiedAt) { push in
            try push(data)
        }
    }

    @discardableResult
    public func add(
        file: URL, at path: String, modifiedAt: Date? = nil
    ) throws(ZipFailure)
        -> Entry
    {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let stamp = modifiedAt ?? values?.contentModificationDate ?? Date()
        guard let reader = try? FileHandle(forReadingFrom: file) else {
            throw ZipFailure.cannotRead(file.lastPathComponent)
        }
        defer { try? reader.close() }

        let chunk = chunkSize
        do {
            return try add(path: path, size: size, modifiedAt: stamp) { push in
                while true {
                    let bytes = reader.readData(ofLength: chunk)
                    if bytes.isEmpty { return }
                    try push(bytes)
                }
            }
        } catch let failure as ZipFailure {
            throw failure
        } catch {
            throw ZipFailure.cannotRead(file.lastPathComponent)
        }
    }

    /// The one path every entry takes. `source` pushes the bytes in
    /// whatever chunks it has.
    private func add(
        path: String,
        size: Int64,
        modifiedAt: Date,
        source: ((Data) throws -> Void) throws -> Void
    ) throws(ZipFailure) -> Entry {
        guard paths.insert(path).inserted else { throw ZipFailure.duplicatePath(path) }

        let deflates = Self.deflates(path: path, size: size)
        let start = offset
        let name = Array(path.utf8)
        write(localHeader(name: name, modifiedAt: modifiedAt, deflates: deflates))

        var crc: UInt32 = 0
        var uncompressed: Int64 = 0
        var compressed: Int64 = 0
        var body = DeflateBody(deflates: deflates)

        do {
            try source { chunk in
                crc = RawDeflate.crc32(chunk, seed: crc)
                uncompressed += Int64(chunk.count)
                let out = try body.push(chunk)
                compressed += Int64(out.count)
                self.write(out)
            }
            let tail = try body.finish()
            compressed += Int64(tail.count)
            write(tail)
        } catch let failure as ZipFailure {
            throw failure
        } catch {
            throw ZipFailure.compressionFailed(path)
        }

        patchTheHeader(
            at: start, name: name.count, crc: crc, compressed: compressed,
            uncompressed: uncompressed)

        let entry = Entry(
            path: path,
            uncompressedSize: uncompressed,
            compressedSize: compressed,
            crc: crc,
            isDeflated: body.isDeflating,
            offset: start,
            modifiedAt: modifiedAt)
        entries.append(entry)
        return entry
    }

    /// An already-compressed file gains nothing from DEFLATE, and a
    /// platform with no streaming compressor stores what it cannot
    /// hold in memory.
    private static func deflates(path: String, size: Int64) -> Bool {
        if !RawDeflate.compressesAStream && size > Int64(RawDeflate.bufferLimit) { return false }
        let name = path.lowercased()
        for suffix in storedSuffixes where name.hasSuffix(suffix) { return false }
        return true
    }

    private static let storedSuffixes = [
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ogg", ".mp3", ".m4a", ".aac", ".mp4",
        ".zip", ".7z", ".rar", ".rgssad", ".rgss2a", ".rgss3a",
    ]

    // MARK: - The end of the file

    /// Writes the central directory and both ZIP64 end records.
    public func finish() throws(ZipFailure) {
        let directoryStart = offset
        for entry in entries { write(centralHeader(entry)) }
        let directorySize = offset - directoryStart

        write(zip64EndRecord(start: directoryStart, size: directorySize))
        write(zip64Locator(at: directoryStart + directorySize))
        write(endRecord(start: directoryStart, size: directorySize))

        do {
            try handle.close()
        } catch {
            throw ZipFailure.writeFailed(url.lastPathComponent)
        }
    }

    public func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - The records

    private static let zip64Version: UInt16 = 45
    /// Bit 11 says the name is UTF-8.
    private static let utf8Flag: UInt16 = 0x0800
    private static let unknown32: UInt32 = 0xFFFF_FFFF

    private func localHeader(name: [UInt8], modifiedAt: Date, deflates: Bool) -> Data {
        var out = Data()
        out.append(le32: 0x0403_4B50)
        out.append(le16: Self.zip64Version)
        out.append(le16: Self.utf8Flag)
        out.append(le16: deflates ? 8 : 0)
        out.append(le32: Self.dosStamp(modifiedAt))
        // The CRC and the two sizes are unknown until the entry
        // ends, so the local header always carries the ZIP64 extra
        // field and `patchTheHeader` fills it in.
        out.append(le32: 0)
        out.append(le32: Self.unknown32)
        out.append(le32: Self.unknown32)
        out.append(le16: UInt16(name.count))
        out.append(le16: 20)
        out.append(contentsOf: name)
        out.append(le16: 0x0001)
        out.append(le16: 16)
        out.append(le64: 0)
        out.append(le64: 0)
        return out
    }

    private func patchTheHeader(
        at start: Int64, name: Int, crc: UInt32, compressed: Int64, uncompressed: Int64
    ) {
        var head = Data()
        head.append(le32: crc)
        try? handle.seek(toOffset: UInt64(start + 14))
        handle.write(head)

        var sizes = Data()
        sizes.append(le64: uncompressed)
        sizes.append(le64: compressed)
        try? handle.seek(toOffset: UInt64(start + 30 + Int64(name) + 4))
        handle.write(sizes)

        try? handle.seek(toOffset: UInt64(offset))
    }

    private func centralHeader(_ entry: Entry) -> Data {
        let name = Array(entry.path.utf8)
        var extra = Data()
        let limit = Int64(Self.unknown32)
        if entry.uncompressedSize >= limit { extra.append(le64: entry.uncompressedSize) }
        if entry.compressedSize >= limit { extra.append(le64: entry.compressedSize) }
        if entry.offset >= limit { extra.append(le64: entry.offset) }

        var out = Data()
        out.append(le32: 0x0201_4B50)
        out.append(le16: Self.zip64Version)
        out.append(le16: Self.zip64Version)
        out.append(le16: Self.utf8Flag)
        out.append(le16: entry.isDeflated ? 8 : 0)
        out.append(le32: Self.dosStamp(entry.modifiedAt))
        out.append(le32: entry.crc)
        out.append(le32: Self.field(entry.compressedSize))
        out.append(le32: Self.field(entry.uncompressedSize))
        out.append(le16: UInt16(name.count))
        out.append(le16: extra.isEmpty ? 0 : UInt16(extra.count + 4))
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le32: 0)
        out.append(le32: Self.field(entry.offset))
        out.append(contentsOf: name)
        if !extra.isEmpty {
            out.append(le16: 0x0001)
            out.append(le16: UInt16(extra.count))
            out.append(extra)
        }
        return out
    }

    private func zip64EndRecord(start: Int64, size: Int64) -> Data {
        var out = Data()
        out.append(le32: 0x0606_4B50)
        // The size of what follows this field, which is 44 for a
        // record with no extensible data.
        out.append(le64: 44)
        out.append(le16: Self.zip64Version)
        out.append(le16: Self.zip64Version)
        out.append(le32: 0)
        out.append(le32: 0)
        out.append(le64: Int64(entries.count))
        out.append(le64: Int64(entries.count))
        out.append(le64: size)
        out.append(le64: start)
        return out
    }

    private func zip64Locator(at record: Int64) -> Data {
        var out = Data()
        out.append(le32: 0x0706_4B50)
        out.append(le32: 0)
        out.append(le64: record)
        out.append(le32: 1)
        return out
    }

    private func endRecord(start: Int64, size: Int64) -> Data {
        let count = entries.count >= 0xFFFF ? UInt16(0xFFFF) : UInt16(entries.count)
        var out = Data()
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: count)
        out.append(le16: count)
        out.append(le32: Self.field(size))
        out.append(le32: Self.field(start))
        out.append(le16: 0)
        return out
    }

    /// A value the 32-bit field cannot hold reads as `0xFFFFFFFF`
    /// and moves to the ZIP64 record.
    private static func field(_ value: Int64) -> UInt32 {
        value >= Int64(unknown32) ? unknown32 : UInt32(value)
    }

    /// The MS-DOS stamp of the appnote: seconds in units of two, and
    /// a year counted from 1980. It reads UTC, so one package holds
    /// the same stamps whatever time zone wrote it.
    static func dosStamp(_ date: Date) -> UInt32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980) - 1980
        let time =
            UInt32((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt32(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return day << 16 | time
    }

    private func write(_ data: Data) {
        guard !data.isEmpty else { return }
        handle.write(data)
        offset += Int64(data.count)
    }
}

/// The compressor of one entry, which is either DEFLATE or nothing.
private struct DeflateBody {

    private(set) var isDeflating: Bool
    #if canImport(Compression)
    private var stream: DeflateStream?
    #else
    private var buffered = Data()
    #endif

    init(deflates: Bool) {
        #if canImport(Compression)
        stream = deflates ? DeflateStream.encoder() : nil
        isDeflating = deflates && stream != nil
        #else
        isDeflating = deflates
        #endif
    }

    mutating func push(_ chunk: Data) throws -> Data {
        guard isDeflating else { return chunk }
        #if canImport(Compression)
        guard let out = stream?.push(chunk) else { throw ZipFailure.compressionFailed("") }
        return out
        #else
        buffered.append(chunk)
        return Data()
        #endif
    }

    mutating func finish() throws -> Data {
        guard isDeflating else { return Data() }
        #if canImport(Compression)
        guard let out = stream?.finish() else { throw ZipFailure.compressionFailed("") }
        return out
        #else
        guard let out = RawDeflate.deflate(buffered) else {
            throw ZipFailure.compressionFailed("")
        }
        buffered = Data()
        return out
        #endif
    }
}

extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    mutating func append(le64 value: Int64) {
        let bits = UInt64(bitPattern: value)
        append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) })
    }
}
