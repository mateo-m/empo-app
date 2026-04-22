import SwiftUI

/// `.frame` must be directly on the Image (not a parent wrapper)
/// for `.fill` aspect ratio to clip correctly.
struct GameArtworkView: View {
    let artworkPath: String?
    var placeholderIcon: String = "gamecontroller.fill"
    var placeholderIconSize: CGFloat = 36
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 0
    var importing: Bool = false
    var shimmer: Bool = true

    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        content
            .saturation(importing ? 0 : 1)
            .animation(Motion.standard, value: importing)
            .overlay {
                if shimmer && artworkPath != nil && !importing {
                    shimmerOverlay
                }
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
        if let path = artworkPath, let uiImage = ImageCache.shared.image(for: path) {
            sized(loadedArtwork(path: path, uiImage: uiImage))
        } else {
            sized(placeholderContent)
        }
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
    /// backgrounds; stretching them to `.fill` would let the
    /// transparency reveal whatever surface sits behind the card,
    /// which looks wrong when the artwork is meant to be the
    /// card's focal point. Route those through the composite
    /// branch so the icon floats on the same gradient the
    /// empty-state placeholder uses.
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
            Image(systemName: placeholderIcon)
                .font(.system(size: placeholderIconSize))
                .foregroundStyle(.quaternary)
        }
    }

    /// Shared backdrop for the empty placeholder and the
    /// icon-composite path. Base uses secondarySystemBackground
    /// so light mode lands on a soft gray instead of pure white
    /// (which reads cheap next to vibrant artwork on sibling
    /// cards). A subtle top-to-bottom highlight gradient adds
    /// depth so the surface feels crafted rather than flat.
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
    /// it - PE icons are typically 128-256px whereas the card
    /// itself can be substantially larger, so stretching would
    /// blur them. Inset scales to the container so the icon
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
    /// extracted from `Game.exe`. Using the filename as the
    /// signal avoids per-pixel alpha scans and stays consistent
    /// with the side that wrote the file.
    private func isExecutableIconSidecar(path: String) -> Bool {
        (path as NSString).lastPathComponent == ExecutableIconExtractor.sidecarFilename
    }
}
