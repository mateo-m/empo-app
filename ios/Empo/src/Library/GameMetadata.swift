import Foundation
import UIKit

/// Per-game metadata stored at `<container>/Metadata/metadata.json`,
/// with custom artwork/banner images alongside it as
/// `<container>/Metadata/<filename>.jpg`.
///
/// All path math goes through `GameContainer`; this type is just the
/// codable struct + load/save/image helpers. Survives game directory
/// clearing only insofar as the container survives - on game delete
/// the entire container is rm'd, metadata included.
struct GameMetadata: Codable {
    var dateAdded: Date?
    var lastPlayed: Date?
    var totalPlayTime: TimeInterval?   // wall-clock seconds (unaffected by fast forward)
    var customTitle: String?
    var customArtworkFilename: String?  // e.g. "artwork.jpg", relative to <container>/Metadata/
    var customBannerFilename: String?   // e.g. "banner.jpg", relative to <container>/Metadata/

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


    static func load(from container: GameContainer) -> GameMetadata {
        let url = container.metadataJSONURL
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

    func save(to container: GameContainer) {
        container.ensureMetadataDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: container.metadataJSONURL, options: .atomic)
        }
    }


    private func customMediaPath(filename: String?, in container: GameContainer) -> String? {
        guard let filename else { return nil }
        let path = container.metadataURL
            .appendingPathComponent(filename).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func customArtworkPath(in container: GameContainer) -> String? {
        customMediaPath(filename: customArtworkFilename, in: container)
    }

    func customBannerPath(in container: GameContainer) -> String? {
        customMediaPath(filename: customBannerFilename, in: container)
    }


    @discardableResult
    static func saveImage(_ image: UIImage, as name: String, in container: GameContainer) -> String? {
        let dir = container.ensureMetadataDirectory()

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

    static func removeImage(named filename: String, in container: GameContainer) {
        let url = container.metadataURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }


    /// Returns containers whose metadata has the given JGP manifest
    /// id. Used to detect when a user imports the same JGP archive
    /// twice so the import flow can offer to replace the existing
    /// entry or add a second copy.
    static func containers(withManifestId manifestId: String) -> [GameContainer] {
        return GameContainer.discover().filter { container in
            let metadata = load(from: container)
            return metadata.manifestId == manifestId
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

            // NSEnumerator's `for case let x in enumerator` form
            // calls `makeIterator()`, which Swift 6 treats as
            // unavailable from async contexts. Manual `nextObject()`
            // loop sidesteps that and still walks the whole tree.
            var total: Int64 = 0
            while let next = enumerator.nextObject() {
                guard let fileURL = next as? URL else { continue }
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


    /// Detect the game's RGSS API version (1 = XP, 2 = VX,
    /// 3 = VX Ace). Returns nil when no signal is found.
    ///
    /// RGSS version is the *graphics API* version (Sprite/Bitmap/
    /// Window/Tilemap conventions), not the Ruby parser version.
    /// A modern custom engine can ship RGSS1 graphics with Ruby 3.x
    /// (Pokemon Flux), so this is independent of the bundled Ruby.
    ///
    /// Priority of signals (each catches games the next misses):
    ///   1. `mkxp.json` `rgssVersion` integer (developer-declared,
    ///      highest authority).
    ///   2. `Game.ini` `Scripts=` path extension. `.rxdata` = 1,
    ///      `.rvdata` = 2, `.rvdata2` = 3. Vanilla RPG Maker writes
    ///      this; PE forks and most fan engines preserve it.
    ///   3. Archive presence: `.rgssad` = 1, `.rgss2a` = 2,
    ///      `.rgss3a` = 3. Encrypted-script games often only ship
    ///      these and a stub Game.ini.
    ///   4. Loose `Data/` files: prefer the highest-numbered family
    ///      present (`.rvdata2` > `.rvdata` > `.rxdata`) since
    ///      newer-format files coexist with older ones in some
    ///      hybrid games.
    static func detectRGSSVersion(in gameDirectory: URL) -> Int? {
        let fm = FileManager.default

        // Signal 1: mkxp.json
        let mkxpURL = gameDirectory.appendingPathComponent("mkxp.json")
        if let data = try? Data(contentsOf: mkxpURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = json["rgssVersion"] as? Int,
           (1...3).contains(v) {
            return v
        }

        // Signal 2: Game.ini Scripts= extension
        let iniURL = gameDirectory.appendingPathComponent("Game.ini")
        if let scripts = GameEntry.parseINIValue(in: iniURL, section: "game", key: "scripts") {
            let lower = scripts.lowercased()
            if lower.hasSuffix(".rvdata2") { return 3 }
            if lower.hasSuffix(".rvdata")  { return 2 }
            if lower.hasSuffix(".rxdata")  { return 1 }
        }

        // Signal 3: archives at game root or in Data/
        let archiveCandidates = [gameDirectory, gameDirectory.appendingPathComponent("Data")]
        for dir in archiveCandidates {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                if lower.hasSuffix(".rgss3a") { return 3 }
                if lower.hasSuffix(".rgss2a") { return 2 }
                if lower.hasSuffix(".rgssad") { return 1 }
            }
        }

        // Signal 4: loose Data/* files
        let dataDir = gameDirectory.appendingPathComponent("Data")
        if let entries = try? fm.contentsOfDirectory(atPath: dataDir.path) {
            var sawRxdata = false
            var sawRvdata = false
            var sawRvdata2 = false
            for entry in entries {
                let lower = entry.lowercased()
                if lower.hasSuffix(".rvdata2") { sawRvdata2 = true }
                else if lower.hasSuffix(".rvdata") { sawRvdata = true }
                else if lower.hasSuffix(".rxdata") { sawRxdata = true }
            }
            if sawRvdata2 { return 3 }
            if sawRvdata  { return 2 }
            if sawRxdata  { return 1 }
        }

        return nil
    }


    /// Detect the bundled Ruby version a game ships, if any.
    /// Returns the version string (e.g., `"3.1.0p0"`) or nil when
    /// no bundled runtime is found (game runs against the engine's
    /// own Ruby).
    ///
    /// Robust to filename: scans the byte contents of every
    /// `.dll`/`.dylib`/`.so` in the game folder for Ruby's embedded
    /// `RUBY_DESCRIPTION` literal (`"ruby X.Y.ZpN"`). A developer
    /// can rename the DLL to `bundled.dll` and we still find it.
    /// Files larger than 64 MB are skipped as a safety bound -
    /// real Ruby DLLs are 5-15 MB.
    static func detectBundledRubyVersion(in gameDirectory: URL) -> String? {
        let fm = FileManager.default
        let binaryExtensions: Set<String> = ["dll", "dylib", "so"]
        let scanBudget = 64 * 1024 * 1024

        guard let entries = try? fm.contentsOfDirectory(atPath: gameDirectory.path) else { return nil }
        for entry in entries {
            let ext = (entry as NSString).pathExtension.lowercased()
            guard binaryExtensions.contains(ext) else { continue }

            let url = gameDirectory.appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  size <= scanBudget,
                  let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { continue }

            if let v = scanRubyDescription(in: data) { return v }
        }

        return nil
    }


    /// Read the host engine's Ruby version by scanning the app's
    /// own executable for the same `RUBY_DESCRIPTION` literal we
    /// look for in bundled DLLs. Cached on first call: the
    /// binary doesn't change between calls so the scan is wasted
    /// after the first hit.
    ///
    /// Returns nil only on the (unexpected) case where the scan
    /// can't find a version string in our own binary - which
    /// would mean Ruby was dynamically linked with the version
    /// stripped, neither of which we currently do.
    static func engineRubyVersion() -> String? {
        if let cached = _engineRubyVersionCache.value { return cached }
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let v = scanRubyDescription(in: data)
        else { return nil }
        _engineRubyVersionCache.value = v
        return v
    }


    /// Search a binary blob for Ruby's embedded `RUBY_DESCRIPTION`
    /// literal (`"ruby X.Y.ZpN"`) and return the version capture.
    /// Decodes the bytes as Latin-1 (each byte maps 1:1 to U+0000
    /// through U+00FF) so binary data round-trips losslessly into
    /// a Swift String for `NSRegularExpression` to scan. ASCII
    /// decoding would return nil here because real binaries
    /// contain bytes 128-255.
    private static func scanRubyDescription(in data: Data) -> String? {
        guard let regex = _rubyVersionRegex else { return nil }
        // Latin-1 decode is lossless for any byte sequence; the
        // resulting String has the same length in Unicode scalars
        // as the input has in bytes, so regex offsets are stable.
        let asciiString = String(data: data, encoding: .isoLatin1) ?? ""
        let range = NSRange(asciiString.startIndex..., in: asciiString)
        guard let match = regex.firstMatch(in: asciiString, options: [], range: range),
              match.numberOfRanges >= 2,
              let versionRange = Range(match.range(at: 1), in: asciiString)
        else { return nil }
        return String(asciiString[versionRange])
    }

    // Cached, lazily-built regex. Pattern matches "ruby 1.8.7",
    // "ruby 2.6.10", "ruby 3.1.0p0", "ruby 3.4.0p1234" - tolerant
    // of patch suffix. Anchors on the literal "ruby " prefix so
    // unrelated version strings inside the binary don't match.
    private static let _rubyVersionRegex = try? NSRegularExpression(
        pattern: #"ruby (\d+\.\d+\.\d+(?:p\d+)?)"#
    )
}

/// Single-shot cache wrapper for `engineRubyVersion()`. Swift
/// doesn't let us easily mutate a `static var` from inside a
/// `static func` without `nonisolated(unsafe)` ceremony; a
/// reference-typed holder is the cleanest workaround that keeps
/// the value type semantics clean elsewhere.
private final class _EngineRubyVersionCache: @unchecked Sendable {
    var value: String?
}
private let _engineRubyVersionCache = _EngineRubyVersionCache()


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
