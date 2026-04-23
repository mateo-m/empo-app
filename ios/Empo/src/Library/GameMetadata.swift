import Foundation
import UIKit

/// Per-game metadata stored in `Documents/Metadata/`, survives game directory clearing.
struct GameMetadata: Codable {
    var dateAdded: Date?
    var lastPlayed: Date?
    var totalPlayTime: TimeInterval?   // wall-clock seconds (unaffected by fast forward)
    var customTitle: String?
    var customArtworkFilename: String?  // e.g. "artwork.jpg", stored in Metadata/{id}/
    var customBannerFilename: String?   // e.g. "banner.jpg", stored in Metadata/{id}/

    // Title sourced from the import, not from a user edit. For JGP
    // imports this comes from the manifest's `name` field, which
    // the packager chose on purpose (often cleaner than what
    // Game.ini happens to say). The library uses this as the base
    // title, but users can still override it with `customTitle`
    // afterwards. nil for non-JGP imports, which fall back to
    // Game.ini's title as the base.
    var baseTitle: String?

    // JoiPlay JGP manifest fields carried over at import time. Shared
    // across all imports of the same JGP so we can detect duplicates
    // when the same archive is imported twice and offer the user a
    // replace/duplicate/cancel choice.
    var manifestId: String?
    var manifestVersion: String?
    var manifestDescription: String?


    private static var metadataDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Metadata", isDirectory: true)
    }

    static func mediaDirectory(for gameId: String) -> URL {
        metadataDirectory.appendingPathComponent(gameId, isDirectory: true)
    }

    private static func metadataURL(for gameId: String) -> URL {
        metadataDirectory.appendingPathComponent("\(gameId).json")
    }


    static func load(for gameId: String) -> GameMetadata {
        let url = metadataURL(for: gameId)
        guard let data = try? Data(contentsOf: url) else { return GameMetadata() }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = (try? decoder.decode(GameMetadata.self, from: data)) ?? GameMetadata()
        metadata.sanitize()
        return metadata
    }


    /// Cleans up values that could be corrupt from external edits.
    mutating func sanitize() {
        let now = Date()
        if let d = dateAdded, d > now { dateAdded = now }
        if let d = lastPlayed, d > now { lastPlayed = now }

        if let t = totalPlayTime, t < 0 { totalPlayTime = nil }

        if let t = customTitle {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            customTitle = trimmed.isEmpty ? nil : trimmed
        }

        if let f = customArtworkFilename, !isValidFilename(f) { customArtworkFilename = nil }
        if let f = customBannerFilename, !isValidFilename(f) { customBannerFilename = nil }
    }

    private func isValidFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    func save(for gameId: String) {
        let fm = FileManager.default
        let dir = Self.metadataDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.metadataURL(for: gameId), options: .atomic)
        }
    }

    static func delete(for gameId: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: metadataURL(for: gameId))
        let mediaDir = mediaDirectory(for: gameId)
        if fm.fileExists(atPath: mediaDir.path) {
            try? fm.removeItem(at: mediaDir)
        }
    }


    private func customMediaPath(filename: String?, for gameId: String) -> String? {
        guard let filename else { return nil }
        let path = Self.mediaDirectory(for: gameId)
            .appendingPathComponent(filename).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func customArtworkPath(for gameId: String) -> String? {
        customMediaPath(filename: customArtworkFilename, for: gameId)
    }

    func customBannerPath(for gameId: String) -> String? {
        customMediaPath(filename: customBannerFilename, for: gameId)
    }


    @discardableResult
    static func saveImage(_ image: UIImage, as name: String, for gameId: String) -> String? {
        let fm = FileManager.default
        let dir = mediaDirectory(for: gameId)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Resize to reasonable dimensions to save disk space
        let maxDimension: CGFloat = name.contains("banner") ? 1200 : 512
        let resized = image.resizedToFit(maxDimension: maxDimension)

        let filename = name.hasSuffix(".jpg") ? name : "\(name).jpg"
        let url = dir.appendingPathComponent(filename)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }

        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            NSLog("[GameMetadata] Failed to save image: %@", error.localizedDescription)
            return nil
        }
    }

    static func removeImage(named filename: String, for gameId: String) {
        let url = mediaDirectory(for: gameId).appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }


    /// Returns any game IDs whose metadata has the given JGP manifest id.
    /// Used to detect when a user imports the same JGP archive twice so
    /// the import flow can offer to replace the existing entry or add a
    /// second copy.
    static func gameIDs(withManifestId manifestId: String) -> [String] {
        let fm = FileManager.default
        let dir = metadataDirectory
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return entries.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            let gameId = String(name.dropLast(".json".count))
            let metadata = load(for: gameId)
            guard metadata.manifestId == manifestId else { return nil }
            return gameId
        }
    }


    static func diskSize(for directory: URL) async -> Int64 {
        let directory = directory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return Int64(0)
            }

            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
    }


    static func formatPlayTime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "Not played yet" }
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "Less than a minute"
        }
    }

    static func formatDiskSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


private extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
