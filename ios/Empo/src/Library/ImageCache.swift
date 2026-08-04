import CryptoKit
import ImageIO
import Synchronization
import UIKit

/// Two-layer (memory + disk) cache of downsampled artwork thumbnails.
///
/// Library artwork is frequently a game's full title screen (PNG/BMP,
/// often 1920x1080+). Decoding those at native size costs
/// `width * height * 4` bytes and tens of milliseconds each, and doing
/// it synchronously during a SwiftUI body evaluation was the primary
/// source of scroll hitches in the library. Every decode now goes
/// through ImageIO thumbnailing (`kCGImageSourceThumbnailMaxPixelSize`)
/// so the bitmap is bounded by what the target surface can actually
/// show, and `thumbnail(for:)` runs it off the caller's actor.
///
/// Large sources also persist their downsampled result under
/// Caches/ArtworkThumbnails so later launches skip the full-size
/// decode. The OS may purge that directory under storage pressure;
/// entries are simply regenerated on demand.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Pixel budgets for the app's artwork surfaces. `cell` covers the
    /// grid card (about a third of the screen width) and the 48pt list
    /// artwork with retina headroom. `hero` covers the full-width
    /// "Continue playing" card, the Game Info banner, and the loading
    /// view backdrop — sized for the widest case, a 13" iPad in
    /// landscape (~1334pt content width @2x). Only one hero-budget
    /// image is typically alive at a time, so the larger decode
    /// (~8 MB worst case) doesn't threaten the cache ceiling.
    enum PixelBudget {
        static let cell: CGFloat = 768
        static let hero: CGFloat = 2668
    }

    /// Sources at or below this byte size (exe-icon sidecars, small
    /// title screens) decode fast enough that a disk copy of the
    /// thumbnail would only add write traffic.
    private static let diskCacheThresholdBytes = 256 * 1024

    private let cache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL
    private let fm = FileManager.default

    /// Per-path eviction generation. `loadThumbnail` snapshots the
    /// generation before decoding and drops its result if an `evict`
    /// landed mid-decode. Without this, an in-flight decode of
    /// just-replaced bytes (the sidecar/custom-media files are
    /// overwritten at fixed paths) could repopulate the cache
    /// *after* the eviction that was meant to clear them, and the
    /// stale image would then be served until process death.
    private let generations = Mutex<[String: Int]>([:])

    private init() {
        // Thumbnails are bounded (a 16:9 cell thumbnail decodes to
        // roughly half a megabyte), so the count limit can sit well
        // above the old full-size limit while the cost ceiling keeps
        // worst-case memory flat. NSCache drains on memory warnings
        // automatically.
        cache.countLimit = 150
        cache.totalCostLimit = 64 * 1024 * 1024
        diskDirectory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkThumbnails", isDirectory: true)
        try? fm.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        schedulePruneDiskCache()
    }

    /// A disk entry older than this is deleted by the launch prune.
    /// A live entry comes back with one decode on its next load, so
    /// the cost of an over-eager deletion is small. The rule's real
    /// target is entries whose source is gone (deleted games), which
    /// no load or evict will ever touch again.
    private static let maxDiskEntryAge: TimeInterval = 60 * 60 * 24 * 60

    private func schedulePruneDiskCache() {
        let directory = diskDirectory
        Task.detached(priority: .utility) {
            // Stay off the cold-launch disk bandwidth: the initial
            // scan and the first-render decodes own the first
            // seconds.
            try? await Task.sleep(for: .seconds(10))
            Self.pruneDiskCache(directory: directory)
        }
    }

    /// Once-per-launch reclamation of the disk layer. Nothing else
    /// deletes entries orphaned by in-place game updates (a new
    /// source mtime changes the filename and strands the old one),
    /// so without this the directory grows until the OS purges
    /// Caches. Two rules bound it without knowing which paths are
    /// live:
    /// - Per digest and budget, at most the newest source-mtime
    ///   token can match a live source. Older siblings are update
    ///   leftovers and are deleted.
    /// - An entry that was not rewritten for `maxDiskEntryAge` is
    ///   deleted (see the constant's comment).
    /// Deletions tolerate concurrent loads and evicts: writes are
    /// atomic, and a load that loses its disk entry mid-flight
    /// falls back to decoding the source.
    static func pruneDiskCache(directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return }

        // Filename shape: <digest>-<sourceMtime>-<budget>.png
        // (see `diskCacheURL`). Files that do not match are left
        // alone.
        struct Newest {
            let name: String
            let mtimeToken: Int
        }
        var newestPerGroup: [String: Newest] = [:]
        var doomed: [String] = []

        for name in items {
            let parts = name.split(separator: "-")
            guard parts.count == 3, parts[2].hasSuffix(".png"),
                let token = Int(parts[1])
            else { continue }
            let group = "\(parts[0])-\(parts[2])"
            if let current = newestPerGroup[group] {
                if token > current.mtimeToken {
                    doomed.append(current.name)
                    newestPerGroup[group] = Newest(name: name, mtimeToken: token)
                } else {
                    doomed.append(name)
                }
            } else {
                newestPerGroup[group] = Newest(name: name, mtimeToken: token)
            }
        }

        for survivor in newestPerGroup.values {
            let url = directory.appendingPathComponent(survivor.name)
            if let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate])
                as? Date,
                now.timeIntervalSince(mtime) > maxDiskEntryAge
            {
                doomed.append(survivor.name)
            }
        }

        for name in doomed {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Memory-only lookup, cheap enough for SwiftUI body evaluations.
    /// Views use this as a fast path so cells recreated by the lazy
    /// grid/list don't flash their placeholder while the async load
    /// re-delivers an image that is already decoded.
    func cachedThumbnail(for path: String, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: Self.memoryKey(path: path, maxPixelSize: maxPixelSize))
    }

    /// Async load: memory cache, then disk cache, then a downsampled
    /// decode of the source. All I/O and decoding run off the
    /// caller's actor.
    func thumbnail(for path: String, maxPixelSize: CGFloat) async -> UIImage? {
        if let hit = cachedThumbnail(for: path, maxPixelSize: maxPixelSize) {
            return hit
        }
        return await Task.detached(priority: .userInitiated) { [self] in
            loadThumbnail(path: path, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Synchronous load for background contexts that want the cache
    /// primed before the UI reads it (import pipeline, exe-icon
    /// surfacer). Never call on the main thread. Bypasses the
    /// memory-hit fast path so an evict-then-prewarm sequence always
    /// decodes the fresh bytes, even if a stale in-flight load
    /// slipped an old entry back in moments after the evict.
    func prewarmThumbnail(for path: String, maxPixelSize: CGFloat) {
        _ = loadThumbnail(path: path, maxPixelSize: maxPixelSize, force: true)
    }

    /// Where `evict` runs its disk sweep. Callers that overwrite
    /// artwork files in place (exe-icon sidecar, custom
    /// artwork/banner) need `.sync`: the disk names embed only
    /// second-granularity mtimes, and a same-second overwrite reuses
    /// the stale entry's filename unless it's removed before the
    /// next load. Callers that DELETE the source (library entry
    /// removal) can use `.background`: nothing overwrites that path
    /// again, and a later re-import writes a fresh mtime, so the
    /// sweep only reclaims space and need not block the main actor.
    enum DiskSweep {
        case sync
        case background
    }

    /// Drop every cached representation of `path`, memory and disk,
    /// and bump the path's generation so loads already mid-decode
    /// discard their (stale) result instead of re-populating the
    /// cache. The generation bump and memory purge are always
    /// synchronous; `diskSweep` picks where the directory walk runs.
    func evict(path: String, diskSweep: DiskSweep = .sync) {
        generations.withLock { $0[path, default: 0] += 1 }
        for budget in [PixelBudget.cell, PixelBudget.hero] {
            cache.removeObject(forKey: Self.memoryKey(path: path, maxPixelSize: budget))
        }
        let prefix = Self.pathDigest(path)
        let directory = diskDirectory
        switch diskSweep {
        case .sync:
            Self.sweepDisk(prefix: prefix, directory: directory)
        case .background:
            Task.detached(priority: .utility) {
                Self.sweepDisk(prefix: prefix, directory: directory)
            }
        }
    }

    private static func sweepDisk(prefix: String, directory: URL) {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: directory.path) {
            for item in items where item.hasPrefix(prefix) {
                try? fm.removeItem(at: directory.appendingPathComponent(item))
            }
        }
    }

    private func loadThumbnail(
        path: String, maxPixelSize: CGFloat, force: Bool = false
    ) -> UIImage? {
        let key = Self.memoryKey(path: path, maxPixelSize: maxPixelSize)
        if !force, let hit = cache.object(forKey: key) {
            return hit
        }
        let generation = generations.withLock { $0[path] ?? 0 }

        let sourceBytes =
            (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let diskURL = diskCacheURL(path: path, maxPixelSize: maxPixelSize)

        var image: UIImage?
        var freshlyDecoded = false
        if let diskURL, fm.fileExists(atPath: diskURL.path) {
            image = Self.decodeThumbnail(at: diskURL, maxPixelSize: maxPixelSize)
        }
        if image == nil {
            image = Self.decodeThumbnail(
                at: URL(fileURLWithPath: path), maxPixelSize: maxPixelSize)
            freshlyDecoded = image != nil
        }
        guard let image else { return nil }

        // An evict landed while we were decoding: the bytes we read
        // are superseded. Don't publish them to memory or disk;
        // return whatever the eviction's follow-up prewarm cached
        // (nil makes callers fall back to their placeholder until
        // the next load).
        let current = generations.withLock { $0[path] ?? 0 }
        guard current == generation else {
            return cache.object(forKey: key)
        }

        if freshlyDecoded, let diskURL, sourceBytes > Self.diskCacheThresholdBytes,
            let png = image.pngData()
        {
            // PNG keeps the alpha channel PE-extracted icons rely
            // on. Atomic write so concurrent loads of the same
            // artwork can't interleave partial files.
            try? png.write(to: diskURL, options: .atomic)
        }
        cache.setObject(image, forKey: key, cost: decodedCost(image))

        // An evict can also land between the pre-publish check and
        // the writes above. Re-verify and un-publish on mismatch so
        // stale bytes cannot outlive the eviction. This can race a
        // newer load of the same key and drop ITS fresh entry too;
        // that only costs one extra decode on the next read.
        let afterPublish = generations.withLock { $0[path] ?? 0 }
        guard afterPublish == generation else {
            cache.removeObject(forKey: key)
            if let diskURL { try? fm.removeItem(at: diskURL) }
            return nil
        }
        return image
    }

    /// ImageIO decode straight into a bitmap bounded by
    /// `maxPixelSize` on the long edge. Never materializes the
    /// full-size image, and does not upscale smaller sources.
    private static func decodeThumbnail(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, sourceOptions as CFDictionary)
        else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Disk cache name embeds the source's mtime so an artwork file
    /// replaced in place naturally misses the stale entry; `evict`
    /// sweeps everything matching the path digest regardless of
    /// mtime or budget.
    private func diskCacheURL(path: String, maxPixelSize: CGFloat) -> URL? {
        guard
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate])
                as? Date
        else { return nil }
        let name =
            "\(Self.pathDigest(path))-\(Int(mtime.timeIntervalSince1970))-\(Int(maxPixelSize)).png"
        return diskDirectory.appendingPathComponent(name)
    }

    private static func pathDigest(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func memoryKey(path: String, maxPixelSize: CGFloat) -> NSString {
        "\(Int(maxPixelSize))|\(path)" as NSString
    }

    private func decodedCost(_ image: UIImage) -> Int {
        let scale = image.scale
        let w = image.size.width * scale
        let h = image.size.height * scale
        return Int(w * h * 4)  // RGBA8
    }
}
