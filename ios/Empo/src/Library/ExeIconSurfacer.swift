import Foundation

/// Debounced, off-thread PE icon extraction for mid-import artwork.
/// The extraction callback calls `offer` with candidate .exe files
/// (cheap string checks only). A serial queue processes the latest
/// best candidate. `Game.exe` locks the choice.
final class ExeIconSurfacer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "empo.import.exe-icon", qos: .utility)
    private let lock = NSLock()
    private var locked = false
    private var hasTentative = false

    private let container: GameContainer
    private let onSurfaced: @Sendable (String) -> Void

    init(container: GameContainer, onSurfaced: @escaping @Sendable (String) -> Void) {
        self.container = container
        self.onSurfaced = onSurfaced
    }

    /// Called from the extraction callback. Must stay cheap.
    func offer(fileURL: URL, filename: String) {
        let isGameExe = filename.lowercased() == "game.exe"
        let shouldProcess: Bool = lock.withLock {
            if locked { return false }
            if !isGameExe && hasTentative { return false }
            return true
        }
        guard shouldProcess else { return }
        if !isGameExe && ExecutableIconExtractor.isUtilityExecutable(filename: filename) {
            return
        }
        queue.async { [self] in
            let stillWanted = lock.withLock { !locked || isGameExe }
            guard stillWanted else { return }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                let pe = PEImage(data: data),
                let image = pe.extractIcon(),
                let png = image.pngData()
            else {
                return
            }

            container.ensureMetadataDirectory()
            let sidecarURL = container.exeIconSidecarURL
            guard (try? png.write(to: sidecarURL)) != nil else { return }
            // Evict-then-prewarm before announcing the path: the
            // sidecar is overwritten in place, and library cards read
            // the cache first, so the fresh decode must already be
            // cached when the card re-renders.
            ImageCache.shared.evict(path: sidecarURL.path)
            ImageCache.shared.prewarmThumbnail(
                for: sidecarURL.path, maxPixelSize: ImageCache.PixelBudget.cell)

            lock.withLock {
                hasTentative = true
                if isGameExe { locked = true }
            }
            onSurfaced(sidecarURL.path)
        }
    }

    /// Block until queued icon work has drained. Call after the
    /// extract returns, BEFORE moving the tree, so in-flight reads
    /// of tmp files finish first.
    func drain() {
        queue.sync {}
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
