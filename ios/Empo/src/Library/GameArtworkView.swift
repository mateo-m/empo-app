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
    var shimmer: Bool = true
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
                    return
                }
                loadedImage = await ImageCache.shared.thumbnail(
                    for: path, maxPixelSize: maxPixelSize)
            }
            .onAppear {
                guard shimmer && artworkPath != nil else { return }
                withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
                    shimmerPhase = 2
                }
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
        return ImageCache.shared.cachedThumbnail(for: path, maxPixelSize: maxPixelSize)
            ?? loadedImage
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
