import ImageIO
import UIKit

/// Decoded profile skin art, one image per file.
///
/// Art can be a full-resolution photo, so images decode through
/// ImageIO's thumbnailer at the size the screen can show, never at
/// file size. Each file keeps its largest decode: a smaller request
/// (a list thumbnail) reuses it, and a larger one (a bigger window)
/// replaces it, so window resizes never pile up bitmaps. Any profile
/// change empties the cache: art changes are rare and the next draw
/// reloads only what is on screen.
@MainActor
final class SkinArtCache {
    static let shared = SkinArtCache()

    private struct Entry {
        let image: UIImage
        /// The size this decode was asked for. A request at or below
        /// it is served from this entry.
        let maxPixel: CGFloat
    }

    private var entries: [URL: Entry] = [:]
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: .layoutProfileDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let name = note.userInfo?["name"] as? String ?? ""
            MainActor.assumeIsolated {
                self?.invalidate(profile: name)
            }
        }
    }

    /// nil when the file is missing or does not decode as an image.
    func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        if let hit = entries[url], hit.maxPixel >= maxPixel { return hit.image }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        entries[url] = Entry(image: image, maxPixel: maxPixel)
        return image
    }

    /// Drops every entry. Takes the profile name so callers say what
    /// changed, even though clearing everything is simpler and cheap.
    func invalidate(profile _: String) {
        entries.removeAll()
    }
}
