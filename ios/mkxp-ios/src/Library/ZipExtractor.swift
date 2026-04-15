import Foundation
import zlib

enum ZipExtractor {
    enum Error: Swift.Error { case invalid(String) }

    /// Streaming zip extraction -- reads from disk via FileHandle, never loads
    /// the entire archive into memory.
    static func extract(zipURL: URL, to destDir: URL, progress: ((String, Double) -> Void)? = nil) throws {
        NSLog("[ZipExtractor] opening %@", zipURL.path)
        guard let fh = FileHandle(forReadingAtPath: zipURL.path) else {
            throw Error.invalid("Cannot open zip file")
        }
        defer { try? fh.close() }

        let fm = FileManager.default
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw Error.invalid("File too small to be a zip") }

        // 1. Read the tail of the file to find EOCD (max 65557 bytes from the end)
        progress?("Scanning zip structure...", 0)
        let tailSize = min(UInt64(65557), fileSize)
        let tailOffset = fileSize - tailSize
        try fh.seek(toOffset: tailOffset)
        let tailData = try readExactly(fh, count: Int(tailSize))

        guard let eocdRel = findEOCD(in: tailData) else {
            throw Error.invalid("Cannot find end of central directory")
        }

        let cdOffset = Int(readU32(tailData, eocdRel + 16))
        let entryCount = Int(readU16(tailData, eocdRel + 10))
        NSLog("[ZipExtractor] %d entries, central dir at offset %d", entryCount, cdOffset)

        // 2. Read the entire central directory into memory (typically a few MB)
        let eocdAbsolute = Int(tailOffset) + eocdRel
        let cdSize = eocdAbsolute - cdOffset
        guard cdSize > 0 && cdSize < 100_000_000 else {
            throw Error.invalid("Central directory size looks wrong: \(cdSize)")
        }
        try fh.seek(toOffset: UInt64(cdOffset))
        let cdData = try readExactly(fh, count: cdSize)

        // 3. Parse central directory entries and extract files one by one
        var pos = 0
        for i in 0..<entryCount {
            guard pos + 46 <= cdData.count else { break }
            let sig = readU32(cdData, pos)
            guard sig == 0x02014b50 else { break }

            let method = readU16(cdData, pos + 10)
            let compSize = Int(readU32(cdData, pos + 20))
            let uncompSize = Int(readU32(cdData, pos + 24))
            let nameLen = Int(readU16(cdData, pos + 28))
            let extraLen = Int(readU16(cdData, pos + 30))
            let commentLen = Int(readU16(cdData, pos + 32))
            let localHeaderOffset = Int(readU32(cdData, pos + 42))

            let nameData = cdData[cdData.startIndex + pos + 46 ..< cdData.startIndex + pos + 46 + nameLen]
            let name = String(data: nameData, encoding: .utf8) ?? ""

            pos += 46 + nameLen + extraLen + commentLen

            // Skip __MACOSX metadata and empty names
            if name.hasPrefix("__MACOSX/") || name.isEmpty { continue }

            // Report progress
            if i % 50 == 0 || i == entryCount - 1 {
                let shortName = (name as NSString).lastPathComponent
                let pct = Double(i + 1) / Double(entryCount)
                progress?("Extracting (\(i+1)/\(entryCount)): \(shortName)", pct)
            }

            let entryURL = destDir.appendingPathComponent(name)

            if name.hasSuffix("/") {
                try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
            } else {
                // Read the local file header to find where file data starts
                try fh.seek(toOffset: UInt64(localHeaderOffset + 26))
                let localFieldData = try readExactly(fh, count: 4)
                let localNameLen = Int(readU16(localFieldData, 0))
                let localExtraLen = Int(readU16(localFieldData, 2))
                let fileDataStart = UInt64(localHeaderOffset + 30 + localNameLen + localExtraLen)

                // Ensure parent directory exists
                try fm.createDirectory(at: entryURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)

                // Read compressed data from disk
                try fh.seek(toOffset: fileDataStart)
                let compData = try readExactly(fh, count: compSize)

                if method == 0 {
                    // Stored (no compression)
                    try compData.write(to: entryURL)
                } else if method == 8 {
                    // Deflate
                    let decompressed = try inflate(compData, expectedSize: uncompSize)
                    try decompressed.write(to: entryURL)
                }
                // else: unsupported method, skip silently
            }
        }
        NSLog("[ZipExtractor] extraction complete")
    }


    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (compressed as NSData).bytes.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(compressed.count)

        // -MAX_WBITS for raw deflate (no zlib/gzip header)
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Error.invalid("inflateInit failed")
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: max(expectedSize, 256))
        try output.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            stream.next_out = buf.baseAddress!.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(buf.count)
            let ret = zlib.inflate(&stream, Z_FINISH)
            guard ret == Z_STREAM_END || ret == Z_OK else {
                throw Error.invalid("inflate failed: \(ret)")
            }
        }
        output.count = Int(stream.total_out)
        return output
    }


    private static func readExactly(_ fh: FileHandle, count: Int) throws -> Data {
        var remaining = count
        var result = Data(capacity: count)
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: remaining) else { break }
            if chunk.isEmpty { break }
            result.append(chunk)
            remaining -= chunk.count
        }
        guard result.count == count else {
            throw Error.invalid("Short read: expected \(count) bytes, got \(result.count)")
        }
        return result
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) |
               (UInt32(data[base + 1]) << 8) |
               (UInt32(data[base + 2]) << 16) |
               (UInt32(data[base + 3]) << 24)
    }

    private static func findEOCD(in data: Data) -> Int? {
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let count = data.count
        guard count >= 22 else { return nil }
        for i in stride(from: count - 22, through: max(0, count - 65557), by: -1) {
            if data[data.startIndex + i] == sig[0] &&
               data[data.startIndex + i + 1] == sig[1] &&
               data[data.startIndex + i + 2] == sig[2] &&
               data[data.startIndex + i + 3] == sig[3] {
                return i
            }
        }
        return nil
    }
}
