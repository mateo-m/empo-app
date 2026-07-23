import Foundation

/// Extracts zip, 7z, and rar archives via libarchive (shipped with iOS),
/// plus self-extracting `.exe` game installers.
///
/// The archive is read in streaming mode: entries are decompressed one block
/// at a time and written straight to disk, so peak memory stays flat even
/// for multi-gigabyte archives.
///
/// `.exe` archives are Windows extractor stubs with the real payload
/// appended after the PE image. The payload format decides the decoder:
/// - CAB (what RPG Maker's "Compress Game Data" installer produces) goes
///   through the vendored libmspack, because libarchive both mis-locates
///   the cabinet behind decoy `MSCF` bytes in the stub and has a broken
///   LZX decoder (it fails mid-archive on real-world cabinets that 7-Zip
///   and libmspack decode fine, reproduced on upstream libarchive 3.8.7).
/// - 7z/RAR payloads go through libarchive, reading from the sniffed
///   payload offset via seek-translating callbacks.
/// - Anything else falls through to libarchive reading the whole file,
///   which covers zip-based SFX (the seekable zip reader finds the
///   central directory at end-of-file).
enum ArchiveExtractor {
    enum Error: Swift.Error, LocalizedError {
        case openFailed(String)
        case readFailed(String)
        case writeFailed(String)
        case pathEscape(String)
        /// Thrown when the caller's `shouldCancel` closure returns
        /// `true` between libarchive entry reads. Callers use this
        /// to distinguish a user cancel from a genuine error.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .openFailed(let s), .readFailed(let s), .writeFailed(let s), .pathEscape(let s):
                return s
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    struct Inventory: Hashable, Sendable {
        var entryCount: Int = 0
        var totalUncompressedBytes: Int64 = 0
        var allSizesKnown: Bool = true
    }

    /// Supported archive container formats.
    enum Format {
        case zip
        case sevenZip
        case rar
        /// Self-extracting `.exe` archive (CAB, 7z, RAR, or zip payload
        /// behind a Windows extractor stub).
        case exeSfx

        init?(extension ext: String) {
            switch ext.lowercased() {
            case "zip", "jgp": self = .zip
            case "7z": self = .sevenZip
            case "rar": self = .rar
            case "exe": self = .exeSfx
            default: return nil
            }
        }
    }

    /// How the archive's bytes should be decoded. Everything except
    /// `.exeSfx` reads the whole file with libarchive; `.exe` stubs are
    /// content-sniffed to find the embedded payload.
    private enum Backend {
        /// libarchive, reading from `payloadOffset` (0 = whole file).
        case libarchive(payloadOffset: Int64)
        /// Vendored libmspack CAB reader (runs its own embedded-cabinet
        /// search, so no offset is needed).
        case cab
    }

    private static func resolveBackend(for archiveURL: URL) throws -> Backend {
        guard Format(extension: archiveURL.pathExtension) == .exeSfx else {
            return .libarchive(payloadOffset: 0)
        }
        return try sniffSfxPayload(at: archiveURL)
    }

    /// Extract only entries matching `include` from `archiveURL` into
    /// `destDir`. Used by the import pre-flight to pull a small,
    /// targeted subset of the archive (e.g. the `.ini` + scripts
    /// files) for validation without paying the cost of a full
    /// extract.
    ///
    /// Paths passed to `include` are relative to the archive root
    /// (same normalisation as `Peek.entries`).
    static func extractSelective(
        archive archiveURL: URL,
        to destDir: URL,
        shouldCancel: (() -> Bool)? = nil,
        /// When non-nil and returns `true`, the walk stops after
        /// the current entry is processed. Used by pre-flight
        /// validation to short-circuit once the needed scripts
        /// file has been pulled, avoiding a full walk to EOF.
        stopWhen: (() -> Bool)? = nil,
        onEntry: ((_ relativePath: String, _ uncompressedSize: Int64?) -> Void)? = nil,
        include: (String) -> Bool
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let backend = try resolveBackend(for: archiveURL)
        if case .cab = backend {
            try cabExtractSelective(
                archive: archiveURL,
                to: destDir,
                shouldCancel: shouldCancel,
                stopWhen: stopWhen,
                onEntry: onEntry,
                include: include
            )
            return
        }
        guard case .libarchive(let payloadOffset) = backend else { return }

        guard let reader = archive_read_new() else {
            throw Error.openFailed("archive_read_new failed")
        }
        defer { archive_read_free(reader) }

        let stream = try openLibarchiveReader(
            reader, archiveURL: archiveURL, payloadOffset: payloadOffset)
        // Keep the callback client data alive for the whole read loop.
        // archive_read_free itself never touches it (no close callback
        // is registered), so running this before the free defer is safe.
        defer { withExtendedLifetime(stream) {} }

        var entry: OpaquePointer?
        while true {
            if shouldCancel?() == true { throw Error.cancelled }
            let headerResult = archive_read_next_header(reader, &entry)
            if headerResult == ARCHIVE_EOF { break }
            if headerResult == ARCHIVE_RETRY { continue }
            if headerResult < ARCHIVE_WARN {
                throw Error.readFailed(errorString(reader) ?? "Archive read failure")
            }
            guard let entry else { continue }

            guard let cPath = archive_entry_pathname(entry) else {
                archive_read_data_skip(reader)
                continue
            }
            let rawName = String(cString: cPath)
            let relative = rawName.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if relative.hasPrefix("/") || components.contains("..") {
                archive_read_data_skip(reader)
                continue
            }
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative == ".DS_Store" {
                archive_read_data_skip(reader)
                continue
            }

            let fileType = archive_entry_filetype(entry)
            let isDir = (fileType & 0o170000) == 0o040000
            if isDir {
                archive_read_data_skip(reader)
                continue
            }

            let uncompressedSize: Int64? =
                archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
            onEntry?(relative, uncompressedSize)

            if !include(relative) {
                archive_read_data_skip(reader)
                continue
            }

            let outURL = destDir.appendingPathComponent(relative)
            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            _ = try writeEntry(reader: reader, to: outURL)

            if stopWhen?() == true { break }
        }
    }

    /// Extract an archive to `destDir`. Reports progress in [0, 1] via the
    /// optional callback. The callback runs on the caller's thread.
    ///
    /// `onFileWritten` fires after each file is written to disk,
    /// providing the archive-relative path and the URL on disk.
    /// Used by the import pipeline to surface artwork early (as
    /// soon as `Graphics/Titles/*` lands) without waiting for the
    /// full extract to finish.
    static func extract(
        archive archiveURL: URL,
        to destDir: URL,
        shouldCancel: (() -> Bool)? = nil,
        inventory: Inventory? = nil,
        progress: ((String, Double) -> Void)? = nil,
        onFileWritten: ((String, URL) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let backend = try resolveBackend(for: archiveURL)
        if case .cab = backend {
            try cabExtract(
                archive: archiveURL,
                to: destDir,
                shouldCancel: shouldCancel,
                inventory: inventory,
                progress: progress,
                onFileWritten: onFileWritten
            )
            return
        }
        guard case .libarchive(let payloadOffset) = backend else { return }

        // For 7z (standalone or behind an SFX stub) the compressed file
        // size is intentionally ignored when no probe inventory is
        // available. libarchive reads the entire solid compressed block
        // upfront, so `archive_filter_bytes` would jump to ~100% on the
        // first entry even though extraction has barely started.
        let ext = archiveURL.pathExtension.lowercased()
        let is7z = ext == "7z" || ext == "exe"
        let compressedTotalBytes: Int64
        if is7z {
            compressedTotalBytes = 0
        } else {
            compressedTotalBytes =
                (try? fm.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let reader = archive_read_new() else {
            throw Error.openFailed("archive_read_new failed")
        }
        defer { archive_read_free(reader) }

        let stream = try openLibarchiveReader(
            reader, archiveURL: archiveURL, payloadOffset: payloadOffset)
        // Keep the callback client data alive for the whole read loop.
        // archive_read_free itself never touches it (no close callback
        // is registered), so running this before the free defer is safe.
        defer { withExtendedLifetime(stream) {} }

        var bytesProcessed: Int64 = 0
        var uncompressedWritten: Int64 = 0
        var entryIndex = 0

        var entry: OpaquePointer?
        while true {
            if shouldCancel?() == true { throw Error.cancelled }
            let headerResult = archive_read_next_header(reader, &entry)
            if headerResult == ARCHIVE_EOF { break }
            if headerResult == ARCHIVE_RETRY { continue }
            if headerResult < ARCHIVE_WARN {
                throw Error.readFailed(errorString(reader) ?? "Archive read failure")
            }
            guard let entry else { continue }

            guard let cPath = archive_entry_pathname(entry) else { continue }
            let rawName = String(cString: cPath)

            let relative = rawName.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if relative.hasPrefix("/") || components.contains("..") {
                throw Error.pathEscape("Unsafe path in archive: \(rawName)")
            }
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative == ".DS_Store" {
                archive_read_data_skip(reader)
                continue
            }

            let outURL = destDir.appendingPathComponent(relative)

            let fileType = archive_entry_filetype(entry)
            let isDir = (fileType & 0o170000) == 0o040000
            if isDir {
                try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            let written = try writeEntry(reader: reader, to: outURL)
            uncompressedWritten += Int64(written)
            onFileWritten?(relative, outURL)

            entryIndex += 1
            if let progress {
                let pct: Double
                if let inventory,
                    inventory.allSizesKnown,
                    inventory.totalUncompressedBytes > 0
                {
                    pct = min(
                        0.999,
                        max(0.0, Double(uncompressedWritten) / Double(inventory.totalUncompressedBytes)))
                } else if let inventory, inventory.entryCount > 0 {
                    pct = min(0.999, Double(entryIndex) / Double(inventory.entryCount))
                } else if compressedTotalBytes > 0 {
                    let currentOffset = archive_filter_bytes(reader, -1)
                    bytesProcessed = currentOffset > 0 ? currentOffset : bytesProcessed
                    pct = min(1.0, max(0.0, Double(bytesProcessed) / Double(compressedTotalBytes)))
                } else {
                    pct = min(0.99, Double(entryIndex) / 1000.0)
                }
                if entryIndex % 25 == 0 || pct >= 0.99 {
                    progress(rawName, pct)
                }
            }
        }

        progress?("", 1.0)
    }

    @discardableResult
    private static func writeEntry(reader: OpaquePointer, to outURL: URL) throws -> Int {
        guard let stream = OutputStream(url: outURL, append: false) else {
            throw Error.writeFailed("Cannot open output: \(outURL.path)")
        }
        stream.open()
        defer { stream.close() }

        var totalWritten = 0
        while true {
            var buffer: UnsafeRawPointer?
            var size: Int = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(reader, &buffer, &size, &offset)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN {
                throw Error.readFailed(errorString(reader) ?? "Block read failure")
            }
            guard size > 0, let buffer else { continue }

            let written = stream.write(buffer.assumingMemoryBound(to: UInt8.self), maxLength: size)
            if written < 0 {
                throw Error.writeFailed(stream.streamError?.localizedDescription ?? "Write failed")
            }
            totalWritten += written
        }
        return totalWritten
    }

    private static func errorString(_ reader: OpaquePointer) -> String? {
        guard let cStr = archive_error_string(reader) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - libarchive open (whole file or SFX payload offset)

    /// Enables all formats/filters and opens `reader`. For a payload at
    /// an offset (7z/RAR appended to an .exe stub), the file is fed
    /// through offset-translating callbacks so libarchive sees a stream
    /// that starts at the payload. The returned stream object is the
    /// callback client data and must stay alive until the read loop
    /// finishes. Returns nil for the plain whole-file open.
    private static func openLibarchiveReader(
        _ reader: OpaquePointer,
        archiveURL: URL,
        payloadOffset: Int64
    ) throws -> SfxPayloadStream? {
        archive_read_support_format_all(reader)
        archive_read_support_filter_all(reader)

        if payloadOffset == 0 {
            let blockSize = 10 * 1024 * 1024
            let openResult = archiveURL.path.withCString {
                archive_read_open_filename(reader, $0, blockSize)
            }
            guard openResult == ARCHIVE_OK else {
                throw Error.openFailed(openFailureMessage(reader, archiveURL: archiveURL))
            }
            return nil
        }

        guard let stream = SfxPayloadStream(path: archiveURL.path, payloadOffset: payloadOffset)
        else {
            throw Error.openFailed("Cannot open \(archiveURL.lastPathComponent)")
        }
        archive_read_set_callback_data(reader, Unmanaged.passUnretained(stream).toOpaque())
        archive_read_set_read_callback(reader) { _, clientData, bufferOut in
            guard let clientData, let bufferOut else { return -1 }
            return Unmanaged<SfxPayloadStream>.fromOpaque(clientData)
                .takeUnretainedValue()
                .read(into: bufferOut)
        }
        archive_read_set_seek_callback(reader) { _, clientData, offset, whence in
            guard let clientData else { return Int64(ARCHIVE_FATAL) }
            return Unmanaged<SfxPayloadStream>.fromOpaque(clientData)
                .takeUnretainedValue()
                .seek(to: offset, whence: whence)
        }
        archive_read_set_skip_callback(reader) { _, clientData, request in
            guard let clientData else { return 0 }
            return Unmanaged<SfxPayloadStream>.fromOpaque(clientData)
                .takeUnretainedValue()
                .skip(request)
        }
        guard archive_read_open1(reader) == ARCHIVE_OK else {
            throw Error.openFailed(openFailureMessage(reader, archiveURL: archiveURL))
        }
        return stream
    }

    private static func openFailureMessage(_ reader: OpaquePointer, archiveURL: URL) -> String {
        if Format(extension: archiveURL.pathExtension) == .exeSfx {
            return "\(archiveURL.lastPathComponent) does not look like a "
                + "self-extracting archive. Empo can import only .exe files "
                + "that unpack themselves (CAB, 7z, RAR, or zip based)."
        }
        return errorString(reader) ?? "Cannot open archive"
    }

    // MARK: - SFX payload sniffing

    /// Scans the head of a self-extracting .exe for the embedded archive.
    /// Signature hits are validated before being trusted: PE stubs can
    /// contain decoy byte runs (the sample RPG Maker stub has a fake
    /// `MSCF` inside the PE image that trips libarchive's own SFX skip).
    /// Earliest validated hit wins.
    private static func sniffSfxPayload(at archiveURL: URL) throws -> Backend {
        guard let fh = FileHandle(forReadingAtPath: archiveURL.path) else {
            throw Error.openFailed("Cannot open \(archiveURL.lastPathComponent)")
        }
        defer { try? fh.close() }
        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else {
            throw Error.openFailed("Cannot read \(archiveURL.lastPathComponent)")
        }

        let cabSignature = Data([0x4D, 0x53, 0x43, 0x46])  // "MSCF"
        let sevenZipSignature = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])  // "7z"
        let rarSignature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])  // "Rar!", 4 + 5

        // Extractor stubs are small (the RPG Maker one is ~170 KB,
        // and WinRAR/7-Zip SFX modules are a few hundred KB), so the payload
        // signature sits well within the first few MB. Chunks overlap by
        // a signature length so matches never straddle a boundary.
        let chunkSize = 1 << 20
        let overlap = 64
        let scanLimit: UInt64 = min(fileSize, 16 << 20)
        var chunkStart: UInt64 = 0

        while chunkStart < scanLimit {
            try? fh.seek(toOffset: chunkStart)
            guard let chunk = try? fh.read(upToCount: chunkSize + overlap), chunk.count >= 4
            else { break }

            var hit: (offset: UInt64, backend: Backend)?
            func scan(
                _ signature: Data,
                validate: (UInt64) -> Bool,
                backend: (UInt64) -> Backend
            ) {
                var lower = chunk.startIndex
                while let range = chunk.range(of: signature, in: lower..<chunk.endIndex) {
                    let absolute = chunkStart + UInt64(range.lowerBound - chunk.startIndex)
                    if validate(absolute) {
                        if hit == nil || absolute < hit!.offset {
                            hit = (absolute, backend(absolute))
                        }
                        return
                    }
                    lower = chunk.index(after: range.lowerBound)
                }
            }

            scan(
                cabSignature,
                validate: { isValidCabHeader(at: $0, fileHandle: fh, fileSize: fileSize) },
                backend: { _ in .cab }
            )
            scan(
                sevenZipSignature,
                validate: { isValid7zHeader(at: $0, fileHandle: fh) },
                backend: { .libarchive(payloadOffset: Int64($0)) }
            )
            scan(
                rarSignature,
                validate: { isValidRarHeader(at: $0, fileHandle: fh) },
                backend: { .libarchive(payloadOffset: Int64($0)) }
            )

            if let hit { return hit.backend }
            chunkStart += UInt64(chunkSize)
        }

        // No CAB/7z/RAR payload found. Let libarchive try the whole
        // file: zip-based SFX still works this way because the seekable
        // zip reader locates the central directory at end-of-file. A
        // non-archive .exe fails at open with a friendly message.
        return .libarchive(payloadOffset: 0)
    }

    /// Validates a candidate CFHEADER (MS-CAB spec): reserved fields
    /// zero, version 1.3, sane folder/file counts, and declared sizes
    /// that fit inside the actual file.
    private static func isValidCabHeader(
        at offset: UInt64,
        fileHandle: FileHandle,
        fileSize: UInt64
    ) -> Bool {
        try? fileHandle.seek(toOffset: offset)
        guard let header = try? fileHandle.read(upToCount: 36), header.count == 36 else {
            return false
        }
        let bytes = [UInt8](header)
        func u16(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt64 {
            UInt64(u16(i)) | UInt64(u16(i + 2)) << 16
        }
        guard u32(4) == 0, u32(12) == 0, u32(20) == 0 else { return false }  // reserved1-3
        guard bytes[24] == 3, bytes[25] == 1 else { return false }  // version 1.3
        let cbCabinet = u32(8)
        guard cbCabinet >= 36, offset + cbCabinet <= fileSize else { return false }
        let coffFiles = u32(16)
        guard coffFiles >= 36, coffFiles < cbCabinet else { return false }
        guard u16(26) >= 1, u16(28) >= 1 else { return false }  // cFolders, cFiles
        return true
    }

    private static func isValid7zHeader(at offset: UInt64, fileHandle: FileHandle) -> Bool {
        try? fileHandle.seek(toOffset: offset)
        guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else {
            return false
        }
        // Byte 6 is the format major version, 0 for every 7z ever made.
        return header[header.startIndex + 6] == 0
    }

    private static func isValidRarHeader(at offset: UInt64, fileHandle: FileHandle) -> Bool {
        try? fileHandle.seek(toOffset: offset)
        guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else {
            return false
        }
        let b6 = header[header.startIndex + 6]
        let b7 = header[header.startIndex + 7]
        return b6 == 0x00 || (b6 == 0x01 && b7 == 0x00)  // RAR4 / RAR5
    }

    // MARK: - CAB extraction (libmspack)

    /// CAB twin of the libarchive `extractSelective` path: same entry
    /// normalisation, skip rules, and callback semantics.
    private static func cabExtractSelective(
        archive archiveURL: URL,
        to destDir: URL,
        shouldCancel: (() -> Bool)?,
        stopWhen: (() -> Bool)?,
        onEntry: ((_ relativePath: String, _ uncompressedSize: Int64?) -> Void)?,
        include: (String) -> Bool
    ) throws {
        let fm = FileManager.default
        let reader = try CabReader(archiveURL: archiveURL)

        for entry in reader.entries {
            if shouldCancel?() == true { throw Error.cancelled }

            let relative = entry.relativePath
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            if relative.hasPrefix("/") || components.contains("..") { continue }
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative == ".DS_Store" {
                continue
            }

            onEntry?(relative, entry.size)
            if !include(relative) { continue }

            let outURL = destDir.appendingPathComponent(relative)
            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try reader.extract(entry, to: outURL)

            if stopWhen?() == true { break }
        }
    }

    /// CAB twin of the libarchive `extract` path. Entries are walked in
    /// cabinet order, which is also folder-decompression order, so a
    /// solid LZX folder is decoded exactly once. Cancellation is
    /// per-file: libmspack extracts a whole file per call.
    private static func cabExtract(
        archive archiveURL: URL,
        to destDir: URL,
        shouldCancel: (() -> Bool)?,
        inventory: Inventory?,
        progress: ((String, Double) -> Void)?,
        onFileWritten: ((String, URL) -> Void)?
    ) throws {
        let fm = FileManager.default
        let reader = try CabReader(archiveURL: archiveURL)

        // CAB headers always carry uncompressed sizes, so byte-accurate
        // progress is available even without a probe inventory.
        let totalBytes: Int64
        if let inventory, inventory.allSizesKnown, inventory.totalUncompressedBytes > 0 {
            totalBytes = inventory.totalUncompressedBytes
        } else {
            totalBytes = reader.entries.reduce(0) { $0 + $1.size }
        }

        var uncompressedWritten: Int64 = 0
        var entryIndex = 0

        for entry in reader.entries {
            if shouldCancel?() == true { throw Error.cancelled }

            let relative = entry.relativePath
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            if relative.hasPrefix("/") || components.contains("..") {
                throw Error.pathEscape("Unsafe path in archive: \(entry.rawName)")
            }
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative == ".DS_Store" {
                continue
            }

            let outURL = destDir.appendingPathComponent(relative)
            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            try reader.extract(entry, to: outURL)
            uncompressedWritten += entry.size
            onFileWritten?(relative, outURL)

            entryIndex += 1
            if let progress {
                let pct: Double
                if totalBytes > 0 {
                    pct = min(0.999, max(0.0, Double(uncompressedWritten) / Double(totalBytes)))
                } else {
                    pct = min(0.999, Double(entryIndex) / Double(reader.entries.count))
                }
                if entryIndex % 25 == 0 || pct >= 0.99 {
                    progress(entry.rawName, pct)
                }
            }
        }

        progress?("", 1.0)
    }
}

// MARK: - SFX payload stream (libarchive callbacks)

/// Feeds libarchive the tail of a self-extracting .exe as if it were a
/// standalone archive: every seek/tell is translated by the payload's
/// base offset. Used for 7z/RAR payloads whose readers expect the
/// archive to start at offset 0.
private final class SfxPayloadStream {
    private let file: UnsafeMutablePointer<FILE>
    private let payloadOffset: Int64
    private let fileSize: Int64
    private let bufferSize = 1 << 20
    private let buffer: UnsafeMutableRawPointer

    init?(path: String, payloadOffset: Int64) {
        guard let file = fopen(path, "rb") else { return nil }
        fseeko(file, 0, SEEK_END)
        let fileSize = Int64(ftello(file))
        guard payloadOffset >= 0, payloadOffset <= fileSize,
            fseeko(file, off_t(payloadOffset), SEEK_SET) == 0
        else {
            fclose(file)
            return nil
        }
        self.file = file
        self.payloadOffset = payloadOffset
        self.fileSize = fileSize
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
        fclose(file)
    }

    func read(into bufferOut: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        let count = fread(buffer, 1, bufferSize, file)
        bufferOut.pointee = UnsafeRawPointer(buffer)
        if count == 0 && ferror(file) != 0 { return -1 }
        return count
    }

    /// `offset`/`whence` and the return value are in payload space
    /// (0 = start of the embedded archive).
    func seek(to offset: Int64, whence: Int32) -> Int64 {
        let target: Int64
        switch whence {
        case SEEK_SET: target = payloadOffset + offset
        case SEEK_CUR: target = Int64(ftello(file)) + offset
        case SEEK_END: target = fileSize + offset
        default: return Int64(ARCHIVE_FATAL)
        }
        guard target >= payloadOffset, fseeko(file, off_t(target), SEEK_SET) == 0 else {
            return Int64(ARCHIVE_FATAL)
        }
        return target - payloadOffset
    }

    func skip(_ request: Int64) -> Int64 {
        let current = Int64(ftello(file))
        let target = min(current + request, fileSize)
        guard target >= current, fseeko(file, off_t(target), SEEK_SET) == 0 else { return 0 }
        return target - current
    }
}

// MARK: - CAB reader (libmspack)

/// Thin RAII wrapper over the vendored libmspack CAB decompressor.
/// `search()` scans the file for embedded cabinets, validating headers
/// as it goes, which is exactly what self-extracting stubs need.
private final class CabReader {
    struct Entry {
        /// Name as stored in the cabinet (backslash separators).
        let rawName: String
        /// Forward-slash normalised path, relative to the archive root.
        let relativePath: String
        let size: Int64
        fileprivate let file: UnsafeMutablePointer<mscabd_file>
    }

    private let decompressor: UnsafeMutablePointer<mscab_decompressor>
    private let cabinetChain: UnsafeMutablePointer<mscabd_cabinet>
    /// libmspack keeps this pointer inside the cabinet struct and
    /// reopens the file by name during extraction, so it must outlive
    /// the cabinet (freed in deinit after close()).
    private let cPath: UnsafeMutablePointer<CChar>
    let entries: [Entry]

    init(archiveURL: URL) throws {
        guard let decompressor = mspack_create_cab_decompressor(nil) else {
            throw ArchiveExtractor.Error.openFailed("Cannot create CAB decompressor")
        }
        guard let cPath = strdup(archiveURL.path) else {
            mspack_destroy_cab_decompressor(decompressor)
            throw ArchiveExtractor.Error.openFailed("Cannot open \(archiveURL.lastPathComponent)")
        }
        guard let chain = decompressor.pointee.search(decompressor, cPath) else {
            let code = decompressor.pointee.last_error(decompressor)
            mspack_destroy_cab_decompressor(decompressor)
            free(cPath)
            throw ArchiveExtractor.Error.openFailed(
                "No cabinet archive found in \(archiveURL.lastPathComponent)"
                    + " (\(CabReader.describe(code)))")
        }
        self.decompressor = decompressor
        self.cabinetChain = chain
        self.cPath = cPath

        var entries: [Entry] = []
        var cabinet: UnsafeMutablePointer<mscabd_cabinet>? = chain
        while let currentCabinet = cabinet {
            var file: UnsafeMutablePointer<mscabd_file>? = currentCabinet.pointee.files
            while let currentFile = file {
                let rawName = CabReader.decodeFilename(currentFile.pointee)
                entries.append(
                    Entry(
                        rawName: rawName,
                        relativePath: rawName.replacingOccurrences(of: "\\", with: "/"),
                        size: Int64(currentFile.pointee.length),
                        file: currentFile
                    )
                )
                file = currentFile.pointee.next
            }
            cabinet = currentCabinet.pointee.next
        }
        self.entries = entries
    }

    deinit {
        decompressor.pointee.close(decompressor, cabinetChain)
        mspack_destroy_cab_decompressor(decompressor)
        free(cPath)
    }

    func extract(_ entry: Entry, to outURL: URL) throws {
        let result = outURL.path.withCString {
            decompressor.pointee.extract(decompressor, entry.file, $0)
        }
        guard result == MSPACK_ERR_OK else {
            throw ArchiveExtractor.Error.readFailed(
                "Failed to extract \(entry.rawName): \(CabReader.describe(result))")
        }
    }

    /// Cabinet filenames are either UTF-8 or ISO-8859-1, flagged per
    /// file. `String(cString:)` repairs any stray invalid UTF-8.
    private static func decodeFilename(_ file: mscabd_file) -> String {
        guard let cName = file.filename else { return "" }
        if file.attribs & Int32(MSCAB_ATTRIB_UTF_NAME) != 0 {
            return String(cString: cName)
        }
        let data = Data(bytes: cName, count: strlen(cName))
        return String(data: data, encoding: .isoLatin1) ?? String(cString: cName)
    }

    private static func describe(_ code: Int32) -> String {
        switch code {
        case MSPACK_ERR_OPEN: return "cannot open file"
        case MSPACK_ERR_READ: return "read error"
        case MSPACK_ERR_WRITE: return "write error"
        case MSPACK_ERR_SEEK: return "seek error"
        case MSPACK_ERR_NOMEMORY: return "out of memory"
        case MSPACK_ERR_SIGNATURE: return "no cabinet signature"
        case MSPACK_ERR_DATAFORMAT: return "corrupt cabinet data"
        case MSPACK_ERR_CHECKSUM: return "checksum mismatch"
        case MSPACK_ERR_DECRUNCH: return "decompression failed"
        default: return "error \(code)"
        }
    }
}
