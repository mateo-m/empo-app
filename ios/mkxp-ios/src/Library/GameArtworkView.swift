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

    var body: some View {
        content
            .saturation(importing ? 0 : 1)
            .animation(.easeOut(duration: 0.6), value: importing)
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
