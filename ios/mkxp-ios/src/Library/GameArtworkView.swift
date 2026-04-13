import SwiftUI

/// Shared artwork view used by GameCard, GameListRow, and GameInfoView.
/// Displays the game's artwork or a placeholder with a configurable icon.
struct GameArtworkView: View {
    let artworkPath: String?
    var placeholderIcon: String = "gamecontroller.fill"
    var placeholderIconSize: CGFloat = 36

    var body: some View {
        if let path = artworkPath, let uiImage = ImageCache.shared.image(for: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(.tertiarySystemBackground)
                Image(systemName: placeholderIcon)
                    .font(.system(size: placeholderIconSize))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}
