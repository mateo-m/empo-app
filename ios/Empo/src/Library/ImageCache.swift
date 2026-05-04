import UIKit

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 50
        // 64 MB ceiling so a user importing many large banners doesn't
        // push steady-state memory through the roof while still hitting
        // the countLimit cap on typical libraries. NSCache drains on
        // memory warnings automatically.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for path: String) -> UIImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // `preparingForDisplay()` forces the full CGImage decode up
        // front. Without it, the first draw pass triggers the decode
        // on the main thread and produces a visible hitch when
        // scrolling the library grid.
        guard let raw = UIImage(contentsOfFile: path) else { return nil }
        let image = raw.preparingForDisplay() ?? raw
        cache.setObject(image, forKey: key, cost: decodedCost(image))
        return image
    }

    func evict(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    private func decodedCost(_ image: UIImage) -> Int {
        let scale = image.scale
        let w = image.size.width * scale
        let h = image.size.height * scale
        return Int(w * h * 4)  // RGBA8
    }
}
