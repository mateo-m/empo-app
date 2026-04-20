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
            let image = Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
            if let size {
                image
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            } else {
                image
            }
        } else {
            // Base uses secondarySystemBackground so light mode lands on
            // a soft gray instead of pure white (which reads cheap when
            // it sits right next to vibrant artwork on the other cards).
            // A subtle top-to-bottom highlight gradient adds depth so
            // the placeholder feels crafted rather than flat.
            let placeholder = ZStack {
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
                Image(systemName: placeholderIcon)
                    .font(.system(size: placeholderIconSize))
                    .foregroundStyle(.quaternary)
            }
            if let size {
                placeholder
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            } else {
                placeholder
            }
        }
    }
}
