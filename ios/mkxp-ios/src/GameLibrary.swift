import Foundation
import UIKit
import Compression

struct GameEntry: Identifiable, Hashable {
    let id: String          // folder name, used as stable identity
    let path: String        // full path to game folder
    let title: String       // from Game.ini [Game] Title=, or folder name
    let artworkPath: String? // first image in Graphics/Titles/, if any

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool { lhs.id == rhs.id }
}

class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published var games: [GameEntry] = []
    @Published var importStatus: String?  // non-nil = importing in progress
    @Published var importProgress: Double = 0  // 0.0 – 1.0

    private let fm = FileManager.default

    var gamesDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Games", isDirectory: true)
    }

    private init() {
        ensureGamesDirectory()
        reload()
    }

    // MARK: - Scan

    func reload() {
        var entries: [GameEntry] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            if let entry = scanGameFolder(url) {
                entries.append(entry)
            }
        }

        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        DispatchQueue.main.async { self.games = entries }
    }

    private func scanGameFolder(_ url: URL) -> GameEntry? {
        // Must contain at least one game marker file
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return nil }
        let hasMarker = items.contains { name in
            let lower = name.lowercased()
            return lower == "mkxp.json"
                || lower.hasSuffix(".ini")
                || lower.hasSuffix(".rgssad")
                || lower.hasSuffix(".rgss2a")
                || lower.hasSuffix(".rgss3a")
        }
        guard hasMarker else { return nil }

        let folderName = url.lastPathComponent
        let title = parseGameTitle(at: url) ?? folderName
        let artwork = findArtwork(at: url)

        return GameEntry(
            id: folderName,
            path: url.path,
            title: title,
            artworkPath: artwork
        )
    }

    // MARK: - Game.ini parsing

    private func parseGameTitle(at url: URL) -> String? {
        // Look for Game.ini or any .ini
        let iniURL: URL? = {
            let gameIni = url.appendingPathComponent("Game.ini")
            if fm.fileExists(atPath: gameIni.path) { return gameIni }
            if let items = try? fm.contentsOfDirectory(atPath: url.path) {
                for item in items where item.lowercased().hasSuffix(".ini") {
                    return url.appendingPathComponent(item)
                }
            }
            return nil
        }()
        guard let iniURL, let data = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return nil
        }

        // Simple INI parser: look for Title= in [Game] section
        var inGameSection = false
        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inGameSection = trimmed.lowercased().hasPrefix("[game]")
                continue
            }
            if inGameSection && trimmed.lowercased().hasPrefix("title=") {
                let value = String(trimmed.dropFirst("title=".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - Artwork

    private func findArtwork(at url: URL) -> String? {
        let titlesDir = url.appendingPathComponent("Graphics/Titles")
        guard let items = try? fm.contentsOfDirectory(atPath: titlesDir.path) else { return nil }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp"]
        for item in items.sorted() {
            let ext = (item as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                return titlesDir.appendingPathComponent(item).path
            }
        }
        return nil
    }

    // MARK: - Import

    func importGame(from sourceURL: URL, completion: @escaping (Error?) -> Void) {
        ensureGamesDirectory()

        let isZip = sourceURL.pathExtension.lowercased() == "zip"
        let fileName = sourceURL.lastPathComponent

        self.importProgress = 0
        self.importStatus = isZip ? "Reading \(fileName)..." : "Copying \(fileName)..."

        // startAccessingSecurityScopedResource is process-wide,
        // so the background thread can access the URL.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if isZip {
                    try self.importZip(from: sourceURL)
                } else {
                    try self.importFolder(from: sourceURL)
                }
                DispatchQueue.main.async {
                    self.importStatus = nil
                    self.importProgress = 0
                    self.reload()
                    completion(nil)
                }
            } catch {
                NSLog("[GameLibrary] Import error: %@", "\(error)")
                DispatchQueue.main.async {
                    self.importStatus = nil
                    self.importProgress = 0
                    completion(error)
                }
            }
        }
    }

    private func setStatus(_ status: String, progress: Double? = nil) {
        DispatchQueue.main.async {
            self.importStatus = status
            if let progress { self.importProgress = progress }
        }
    }

    private func importFolder(from sourceURL: URL) throws {
        let folderName = sourceURL.lastPathComponent
        let destURL = deduplicatedURL(for: folderName)
        setStatus("Copying \(folderName)...", progress: 0)
        try fm.copyItem(at: sourceURL, to: destURL)
        setStatus("Copying \(folderName)...", progress: 1.0)
    }

    private func importZip(from sourceURL: URL) throws {
        // Unzip to a temporary directory first
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        setStatus("Extracting zip...", progress: 0)
        try ZipExtractor.extract(zipURL: sourceURL, to: tmpDir) { status, progress in
            self.setStatus(status, progress: progress)
        }

        setStatus("Moving files...", progress: 1.0)
        // Find the game root: could be tmpDir itself or a single subfolder
        let gameRoot = try findGameRoot(in: tmpDir)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destURL = deduplicatedURL(for: baseName)
        try fm.moveItem(at: gameRoot, to: destURL)
    }

    /// If the extracted directory contains a single subfolder, return that instead
    private func findGameRoot(in dir: URL) throws -> URL {
        let items = try fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])

        // Filter out __MACOSX
        let meaningful = items.filter { $0.lastPathComponent != "__MACOSX" }

        // If there's exactly one directory, it's probably the game root
        if meaningful.count == 1,
           let single = meaningful.first,
           (try? single.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return single
        }
        return dir
    }

    private func deduplicatedURL(for folderName: String) -> URL {
        var destURL = gamesDirectory.appendingPathComponent(folderName)
        var counter = 2
        while fm.fileExists(atPath: destURL.path) {
            destURL = gamesDirectory.appendingPathComponent("\(folderName) (\(counter))")
            counter += 1
        }
        return destURL
    }

    enum ImportError: LocalizedError {
        case unzipFailed
        case corruptZip(String)
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Failed to extract the zip file."
            case .corruptZip(let detail): return "Corrupt zip file: \(detail)"
            }
        }
    }

    // MARK: - Delete

    func deleteGame(_ entry: GameEntry) {
        try? fm.removeItem(atPath: entry.path)
        reload()
    }

    // MARK: - Helpers

    private func ensureGamesDirectory() {
        if !fm.fileExists(atPath: gamesDirectory.path) {
            try? fm.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Zip Extraction (streaming, uses FileHandle + system zlib)

import zlib

private enum ZipExtractor {
    enum Error: Swift.Error { case invalid(String) }

    /// Streaming zip extraction -- reads from disk via FileHandle, never loads
    /// the entire archive into memory.
    static func extract(zipURL: URL, to destDir: URL, progress: ((String, Double) -> Void)? = nil) throws {
        NSLog("[GameLibrary] ZipExtractor: opening %@", zipURL.path)
        guard let fh = FileHandle(forReadingAtPath: zipURL.path) else {
            throw Error.invalid("Cannot open zip file")
        }
        defer { fh.closeFile() }

        let fm = FileManager.default
        let fileSize = fh.seekToEndOfFile()
        guard fileSize >= 22 else { throw Error.invalid("File too small to be a zip") }

        // 1. Read the tail of the file to find EOCD (max 65557 bytes from the end)
        progress?("Scanning zip structure...", 0)
        let tailSize = min(UInt64(65557), fileSize)
        let tailOffset = fileSize - tailSize
        fh.seek(toFileOffset: tailOffset)
        let tailData = fh.readData(ofLength: Int(tailSize))

        guard let eocdRel = findEOCD(in: tailData) else {
            throw Error.invalid("Cannot find end of central directory")
        }

        let cdOffset = Int(readU32(tailData, eocdRel + 16))
        let entryCount = Int(readU16(tailData, eocdRel + 10))
        NSLog("[GameLibrary] ZipExtractor: %d entries, central dir at offset %d", entryCount, cdOffset)

        // 2. Read the entire central directory into memory (typically a few MB)
        //    We need the CD to know where each file's local header is.
        let eocdAbsolute = Int(tailOffset) + eocdRel
        let cdSize = eocdAbsolute - cdOffset
        guard cdSize > 0 && cdSize < 100_000_000 else {
            throw Error.invalid("Central directory size looks wrong: \(cdSize)")
        }
        fh.seek(toFileOffset: UInt64(cdOffset))
        let cdData = fh.readData(ofLength: cdSize)
        guard cdData.count == cdSize else {
            throw Error.invalid("Could not read full central directory")
        }

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
                fh.seek(toFileOffset: UInt64(localHeaderOffset + 26))
                let localFieldData = fh.readData(ofLength: 4)
                guard localFieldData.count == 4 else { continue }
                let localNameLen = Int(readU16(localFieldData, 0))
                let localExtraLen = Int(readU16(localFieldData, 2))
                let fileDataStart = UInt64(localHeaderOffset + 30 + localNameLen + localExtraLen)

                // Ensure parent directory exists
                try fm.createDirectory(at: entryURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)

                // Read compressed data from disk
                fh.seek(toFileOffset: fileDataStart)
                let compData = fh.readData(ofLength: compSize)

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
        NSLog("[GameLibrary] ZipExtractor: extraction complete")
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

    // MARK: - Binary helpers

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
