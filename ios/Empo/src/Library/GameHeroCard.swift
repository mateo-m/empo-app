import SwiftUI

/// Where a game tap originated from. Used to disambiguate
/// `matchedTransitionSource` when the same game is shown in multiple
/// places at once (e.g. "Continue playing" hero card + the usual grid
/// tile underneath). Each location registers a distinct source id so
/// the exit zoom animation lands on whichever one the user actually
/// tapped.
enum GameTapSource {
    case hero
    case item

    func transitionID(for gameID: String) -> String {
        switch self {
        case .hero: return "\(gameID)-hero"
        case .item: return "\(gameID)-item"
        }
    }
}

/// "Continue playing" hero card used at the top of the library when a
/// recently-played game exists. Same layout is used for grid and list
/// modes, with the aspect ratio varying so the card sizes itself for
/// portrait vs. compact-height layouts.

struct GameHeroCard: View {
    let game: GameEntry
    let isPaused: Bool
    let aspectRatio: CGFloat
    let heroNamespace: Namespace.ID
    let appState: AppState
    let onTap: () -> Void
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        importing: false,
                        shimmer: false
                    )
                }
                .overlay {
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
                // Flatten the artwork + gradient + text labels into a
                // single render pass before the clip shape. Without
                // this, rotation resizes each overlay layer with its
                // own implicit animation, so the gradient (and its
                // underlying Rectangle frame) visibly lags behind the
                // artwork which is a direct ImageView resizing in
                // lockstep with the card frame.
                .compositingGroup()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Continue playing")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(game.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .textShadow()
                            .lineLimit(1)
                    }
                    .padding(Spacing.xl)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isPaused ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .iconShadow()
                        .padding(Spacing.xl)
                }
                .clipShape(.rect(cornerRadius: Radius.lg))
                .cardShadow()
                .matchedTransitionSource(id: GameTapSource.hero.transitionID(for: game.id),
                                         in: heroNamespace) { config in
                    config
                        .background(.black)
                        .clipShape(.rect(cornerRadius: Radius.lg))
                }
        }
        .buttonStyle(CardPressStyle())
        .gameContextMenu(game: game, appState: appState, onPlay: onTap, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
    }
}
