import SwiftUI

/// Shared artwork view used by GameCard, GameListRow, and GameInfoView.
/// Displays the game's artwork or a placeholder with a configurable icon.
///
/// When `size` is provided, the image is framed and clipped internally
/// (required for `.fill` to clip correctly — `.frame` must be directly
/// on the Image, not on a parent wrapper).
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
            .animation(.spring(duration: 0.3, bounce: 0), value: importing)
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
            let placeholder = ZStack {
                Color(.tertiarySystemBackground)
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
