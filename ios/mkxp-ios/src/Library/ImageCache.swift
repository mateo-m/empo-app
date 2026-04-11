import UIKit

/// Thread-safe in-memory image cache backed by NSCache.
/// Automatically evicts under memory pressure.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Limit to ~50 images; NSCache also evicts under memory pressure
        cache.countLimit = 50
    }

    /// Returns a cached image for the given file path, loading from disk if needed.
    func image(for path: String) -> UIImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Removes a specific entry (e.g. after a game is deleted).
    func evict(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    /// Clears the entire cache.
    func clear() {
        cache.removeAllObjects()
    }
}
