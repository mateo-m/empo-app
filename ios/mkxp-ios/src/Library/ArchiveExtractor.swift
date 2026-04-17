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

        var errorDescription: String? {
            switch self {
            case .openFailed(let s), .readFailed(let s), .writeFailed(let s), .pathEscape(let s):
                return s
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
            case "7z":         self = .sevenZip
            case "rar":        self = .rar
            default:           return nil
            }
        }
    }


    /// Extract an archive to `destDir`. Reports progress in [0, 1] via the
    /// optional callback. The callback runs on the caller's thread.
    static func extract(
        archive archiveURL: URL,
        to destDir: URL,
        progress: ((String, Double) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let totalBytes = (try? fm.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        guard let reader = archive_read_new() else {
            throw Error.openFailed("archive_read_new failed")
        }
        defer { archive_read_free(reader) }

        // Enable every format/filter libarchive supports. Small code footprint,
        // and we don't want to guess the format from the extension: JGP files
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

        let destPath = (destDir.path as NSString).standardizingPath
        var bytesProcessed: Int64 = 0
        var entryIndex = 0

        var entry: OpaquePointer?
        while true {
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
            // We split on "/" and check for components that are exactly "..",
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

            let outURL = destDir.appendingPathComponent(relative)
            // Double-check the resolved path stays inside destDir.
            let resolved = (outURL.path as NSString).standardizingPath
            if !resolved.hasPrefix(destPath + "/") && resolved != destPath {
                throw Error.pathEscape("Resolved path escapes destination: \(rawName)")
            }

            let fileType = archive_entry_filetype(entry)
            let isDir = (fileType & 0o170000) == 0o040000 // S_IFDIR
            if isDir {
                try? fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            // Make sure the parent directory exists for nested files.
            let parent = outURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            try writeEntry(reader: reader, to: outURL)

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
            var buffer: UnsafeRawPointer? = nil
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
