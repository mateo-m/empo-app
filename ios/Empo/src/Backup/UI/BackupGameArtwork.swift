import GameProbe
import SwiftUI

/// A game that left the library shows the Empo mark.
struct BackupGameArtwork: View {

    let gameKey: String?

    var body: some View {
        GameArtworkView(
            artworkPath: Self.artworkPath(ofGameKey: gameKey, in: GameLibrary.shared.games),
            placeholderIconSize: 14,
            size: 36,
            cornerRadius: Radius.sm
        )
        .accessibilityHidden(true)
    }

    static func artworkPath(ofGameKey key: String?, in games: [GameEntry]) -> String? {
        games.first { BackupKeys.gameKey(containerFolderName: $0.id) == key }?.artworkPath
    }
}
