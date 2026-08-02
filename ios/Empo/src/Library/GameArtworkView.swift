import SwiftUI

/// `.frame` must be directly on the Image (not a parent wrapper)
/// for `.fill` aspect ratio to clip correctly.
struct GameArtworkView: View {
    let artworkPath: String?
    var placeholderIcon: Image = Image(.empoMark)
    var placeholderIconSize: CGFloat = 36
    var size: CGFloat?
    var cornerRadius: CGFloat = 0
    var importing: Bool = false
    /// One-shot highlight sweep. Off by default: the sweep re-fires
    /// on every lazy-cell recreation, which puts an animated
    /// full-surface overlay on each card entering the viewport
    /// during a scroll. Library cards enable it only for a game
    /// whose import just finished, and `onShimmerFinished` lets
    /// them clear that flag after the single play.
    var shimmer: Bool = false
    var onShimmerFinished: (() -> Void)?
    /// Decode budget for the thumbnail (long-edge pixels). Cells and
    /// list rows use the default; full-width surfaces (hero card)
    /// pass `ImageCache.PixelBudget.hero`.
    var maxPixelSize: CGFloat = ImageCache.PixelBudget.cell
    /// Bump to force a reload when the artwork file is overwritten
    /// in place under an unchanged path (exe-icon sidecar upgrades
    /// mid-import, custom artwork replacement). Folded into the
    /// load task's identity below.
    var reloadToken: Int = 0

    @State private var shimmerPhase: CGFloat = -1
    @State private var loadedImage: UIImage?
    /// The path `loadedImage` was decoded from. The fallback in
    /// `displayedImage` checks it so a surface whose `artworkPath`
    /// changed (hero card switching games, custom artwork removed)
    /// can never render the previous path's image while the new
    /// load is in flight.
    @State private var loadedPath: String?

    var body: some View {
        content
            .saturation(importing ? 0 : 1)
            .animation(Motion.standard, value: importing)
            .overlay {
                if shimmer && artworkPath != nil && !importing {
                    shimmerOverlay
                }
            }
            .task(id: "\(reloadToken)|\(artworkPath ?? "")") {
                guard let path = artworkPath else {
                    loadedImage = nil
                    loadedPath = nil
                    return
                }
                let image = await ImageCache.shared.thumbnail(
                    for: path, maxPixelSize: maxPixelSize)
                // `thumbnail` awaits a detached task, which resumes
                // even after `.task(id:)` cancels this run (a newer
                // id took over). Without this guard, the superseded
                // run's late resume would clobber the newer image.
                guard !Task.isCancelled else { return }
                loadedImage = image
                loadedPath = path
            }
            .onAppear { playShimmer() }
            // The just-imported card is already on screen when its
            // status flips to ready, so `onAppear` has long passed.
            // React to the flag itself for that case.
            .onChange(of: shimmer) { _, isOn in
                if isOn { playShimmer() }
            }
    }

    private func playShimmer() {
        guard shimmer && artworkPath != nil && !importing else { return }
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) { shimmerPhase = -1 }
        withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
            shimmerPhase = 2
        } completion: {
            onShimmerFinished?()
        }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.15), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            startPoint: UnitPoint(x: shimmerPhase - 0.3, y: shimmerPhase - 0.3),
            endPoint: UnitPoint(x: shimmerPhase, y: shimmerPhase)
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        if let path = artworkPath, let uiImage = displayedImage {
            sized(loadedArtwork(path: path, uiImage: uiImage))
        } else {
            sized(placeholderContent)
        }
    }

    /// Cache-first, then the async task's result. The memory lookup
    /// keeps cells recreated by the lazy grid/list while scrolling
    /// painting immediately instead of flashing the placeholder
    /// until the task lands. In-place overwrites under an unchanged
    /// path are handled by `reloadToken` refiring the task, with the
    /// writer's evict + prewarm keeping this cache-first read fresh
    /// in the window before the reload lands.
    private var displayedImage: UIImage? {
        guard let path = artworkPath else { return nil }
        if let cached = ImageCache.shared.cachedThumbnail(
            for: path, maxPixelSize: maxPixelSize)
        {
            return cached
        }
        return loadedPath == path ? loadedImage : nil
    }

    @ViewBuilder
    private func sized<V: View>(_ view: V) -> some View {
        if let size {
            view
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: cornerRadius))
        } else {
            view
        }
    }

    /// Renders the image loaded from disk. PE-extracted icons
    /// (the sidecar files) typically ship with transparent
    /// backgrounds. Stretched to `.fill`, the transparency would
    /// reveal whatever surface sits behind the card. That looks
    /// wrong when the artwork should be the card's focal point.
    /// Route those through the composite branch so the icon
    /// floats on the same gradient the empty-state placeholder
    /// uses.
    @ViewBuilder
    private func loadedArtwork(path: String, uiImage: UIImage) -> some View {
        if isExecutableIconSidecar(path: path) {
            iconComposite(uiImage: uiImage)
        } else {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        ZStack {
            placeholderBackground
            placeholderIcon
                .resizable()
                .scaledToFit()
                .frame(width: placeholderIconSize, height: placeholderIconSize)
                .foregroundStyle(.quaternary)
        }
    }

    /// Shared backdrop for the empty placeholder and the
    /// icon-composite path. The base uses secondarySystemBackground
    /// so light mode lands on a soft gray instead of pure white
    /// (which looks cheap next to colorful artwork on sibling
    /// cards). A subtle top-to-bottom highlight gradient adds
    /// depth so the surface does not look flat.
    @ViewBuilder
    private var placeholderBackground: some View {
        ZStack {
            Color(.secondarySystemBackground)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.05), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Renders a transparent icon artwork centered on the
    /// placeholder gradient. The icon keeps its aspect ratio and
    /// takes up a fraction of the frame so padding shows around
    /// it. PE icons are typically 128-256px, and the card itself
    /// can be much larger, so stretching would blur them.
    /// The inset scales to the container so the icon
    /// reads at the same relative size in the 48pt list row and
    /// the 150pt+ grid card.
    @ViewBuilder
    private func iconComposite(uiImage: UIImage) -> some View {
        ZStack {
            placeholderBackground
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side * 0.75, height: side * 0.75)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Artwork stored at the sidecar path is always a PE icon
    /// extracted from `Game.exe`. The filename as the signal
    /// avoids per-pixel alpha scans and stays consistent with
    /// the side that wrote the file.
    private func isExecutableIconSidecar(path: String) -> Bool {
        (path as NSString).lastPathComponent == ExecutableIconExtractor.sidecarFilename
    }
}
