import Foundation

/// Extracts zip, 7z, and rar archives via libarchive (shipped with iOS).
///
/// The archive is read in streaming mode: entries are decompressed one block
/// at a time and written straight to disk, so peak memory stays flat even
/// for multi-gigabyte archives.
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

    /// Supported archive container formats.
    enum Format {
        case zip
        case sevenZip
        case rar

        init?(extension ext: String) {
            switch ext.lowercased() {
            case "zip", "jgp": self = .zip
            case "7z": self = .sevenZip
            case "rar": self = .rar
            default: return nil
            }
        }
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
        include: (String) -> Bool
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        guard let reader = archive_read_new() else {
            throw Error.openFailed("archive_read_new failed")
        }
        defer { archive_read_free(reader) }

        archive_read_support_format_all(reader)
        archive_read_support_filter_all(reader)

        let blockSize = 10 * 1024 * 1024
        let openResult = archiveURL.path.withCString {
            archive_read_open_filename(reader, $0, blockSize)
        }
        guard openResult == ARCHIVE_OK else {
            throw Error.openFailed(errorString(reader) ?? "Cannot open archive")
        }

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

            if !include(relative) {
                archive_read_data_skip(reader)
                continue
            }

            let outURL = destDir.appendingPathComponent(relative)
            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try writeEntry(reader: reader, to: outURL)

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
        progress: ((String, Double) -> Void)? = nil,
        onFileWritten: ((String, URL) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // For 7z the file size is intentionally ignored and progress trickles
        // progress by entry index. libarchive reads the entire solid
        // compressed block upfront, so `archive_filter_bytes` would
        // jump to ~100% on the first entry even though extraction has
        // barely started, flashing the progress ring as fully-filled.
        let is7z = archiveURL.pathExtension.lowercased() == "7z"
        let totalBytes: Int64
        if is7z {
            totalBytes = 0
        } else {
            totalBytes =
                (try? fm.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let reader = archive_read_new() else {
            throw Error.openFailed("archive_read_new failed")
        }
        defer { archive_read_free(reader) }

        // Enable every format/filter libarchive supports. Small code footprint,
        // and guessing the format from the extension isn't reliable: JGP files
        // can legitimately be identified as zip, but a user could rename a 7z
        // file to something else. libarchive sniffs the content.
        archive_read_support_format_all(reader)
        archive_read_support_filter_all(reader)

        // 10 MiB block size: balances syscall overhead against memory. The
        // archive itself is never fully loaded; this is just the read window.
        let blockSize = 10 * 1024 * 1024
        let openResult = archiveURL.path.withCString {
            archive_read_open_filename(reader, $0, blockSize)
        }
        guard openResult == ARCHIVE_OK else {
            throw Error.openFailed(errorString(reader) ?? "Cannot open archive")
        }

        var bytesProcessed: Int64 = 0
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

            // Normalise and reject path traversal (zip-slip and friends).
            // Split on "/" and check for components that are exactly "..",
            // not substrings - "file..ext" is a valid filename and must not be
            // rejected.
            let relative = rawName.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if relative.hasPrefix("/") || components.contains("..") {
                throw Error.pathEscape("Unsafe path in archive: \(rawName)")
            }
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative == ".DS_Store" {
                archive_read_data_skip(reader)
                continue
            }

            // The component-level `..` check above is the real defense
            // against zip-slip. A prefix check on the resolved filesystem
            // path is tempting as a belt-and-suspenders guard but it
            // false-positives on iOS real devices where /var and
            // /private/var show up inconsistently between the destDir
            // URL (created from `fm.temporaryDirectory`) and the child
            // path canonicalisation pipelines.
            let outURL = destDir.appendingPathComponent(relative)

            let fileType = archive_entry_filetype(entry)
            let isDir = (fileType & 0o170000) == 0o040000  // S_IFDIR
            if isDir {
                try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            try writeEntry(reader: reader, to: outURL)
            onFileWritten?(relative, outURL)

            entryIndex += 1
            if let progress {
                let currentOffset = archive_filter_bytes(reader, -1)
                bytesProcessed = currentOffset > 0 ? currentOffset : bytesProcessed
                let pct: Double
                if totalBytes > 0 {
                    pct = min(1.0, max(0.0, Double(bytesProcessed) / Double(totalBytes)))
                } else {
                    // No size hint (solid archive): trickle progress every 50 entries.
                    pct = min(0.99, Double(entryIndex) / 1000.0)
                }
                if entryIndex % 25 == 0 || pct >= 0.99 {
                    progress(rawName, pct)
                }
            }
        }

        progress?("", 1.0)
    }

    private static func writeEntry(reader: OpaquePointer, to outURL: URL) throws {
        guard let stream = OutputStream(url: outURL, append: false) else {
            throw Error.writeFailed("Cannot open output: \(outURL.path)")
        }
        stream.open()
        defer { stream.close() }

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
        }
    }

    private static func errorString(_ reader: OpaquePointer) -> String? {
        guard let cStr = archive_error_string(reader) else { return nil }
        return String(cString: cStr)
    }
}
