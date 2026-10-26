import UIKit
import XCTest

@testable import Empo

/// Skin art can be a full-resolution photo, so the cache decodes it
/// downsampled to screen size, and it must reload after the art is
/// replaced while the profile is in use.
@MainActor
final class SkinArtCacheTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkinArtCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePNG(width: Int, height: Int, to name: String) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    private func pixelSize(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testDownsamples() throws {
        let url = try writePNG(width: 4000, height: 2000, to: "skin-landscape.png")
        let cache = SkinArtCache()

        let image = try XCTUnwrap(cache.image(at: url, maxPixel: 1000))

        let size = pixelSize(image)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1000)
    }

    func testInvalidateReloads() throws {
        let url = try writePNG(width: 300, height: 600, to: "skin-portrait.png")
        let cache = SkinArtCache()
        XCTAssertEqual(pixelSize(try XCTUnwrap(cache.image(at: url, maxPixel: 2000))).height, 600)

        _ = try writePNG(width: 200, height: 400, to: "skin-portrait.png")
        cache.invalidate(profile: "Pink")

        XCTAssertEqual(pixelSize(try XCTUnwrap(cache.image(at: url, maxPixel: 2000))).height, 400)
    }

    /// A list thumbnail must not leave a tiny image in the cache for
    /// the full-screen player to pick up.
    func testThumbnailDoesNotShrinkFullSizeArt() throws {
        let url = try writePNG(width: 1200, height: 2600, to: "skin-portrait.png")
        let cache = SkinArtCache()

        _ = cache.image(at: url, maxPixel: 132)
        let full = try XCTUnwrap(cache.image(at: url, maxPixel: 2600))

        XCTAssertEqual(pixelSize(full).height, 2600)
    }

    /// One decoded image per file: window resizes on iPad must not
    /// pile up a full-screen bitmap per size.
    func testSmallerRequestReusesLargerImage() throws {
        let url = try writePNG(width: 1200, height: 2600, to: "skin-portrait.png")
        let cache = SkinArtCache()

        _ = cache.image(at: url, maxPixel: 2600)
        let small = try XCTUnwrap(cache.image(at: url, maxPixel: 1300))

        XCTAssertEqual(pixelSize(small).height, 2600)
    }

    func testUnreadableReturnsNil() throws {
        let url = dir.appendingPathComponent("skin-portrait.jpg")
        try Data("not an image".utf8).write(to: url)

        XCTAssertNil(SkinArtCache().image(at: url, maxPixel: 1000))
    }
}
