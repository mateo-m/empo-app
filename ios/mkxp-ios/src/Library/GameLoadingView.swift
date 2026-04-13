import SwiftUI

struct GameLoadingView: View {
    let game: GameEntry
    var appState = AppState.shared

    /// True when this view is shown for a resume (not a fresh load).
    private var isResume: Bool { appState.pauseSnapshot != nil }

    var body: some View {
        ZStack {
            // Opaque base — ensures nothing behind this view in the
            // NavigationStack (e.g. the game card) bleeds through
            // during the fade-out transition.
            Color.black.ignoresSafeArea()

            if isResume {
                resumeContent
            } else {
                loadingContent
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.black, for: .navigation)
    }

    // MARK: - Loading (fresh launch)

    private var loadingContent: some View {
        ZStack {
            artworkBackground

            VStack(spacing: Spacing.xl) {
                Text(game.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        }
    }

    // MARK: - Resume (snapshot stand-in)
    //
    // When resuming a paused game, the hero zoom animation needs a
    // destination that looks like the game.  But the SDL window is a
    // fullscreen surface behind SwiftUI — it can't participate in view
    // transitions.  So we use the snapshot captured at pause time as a
    // static double: a frozen frame placed at the exact gameRect position
    // (respecting portrait layout, safe areas, etc.).  Once the hero
    // animation finishes, AppState flips to .playing and the real SDL
    // rendering takes over seamlessly.  See docs/pause-resume.md.

    @ViewBuilder
    private var resumeContent: some View {
        if let snapshot = appState.pauseSnapshot {
            let rect = appState.gameRect
            Image(uiImage: snapshot)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .ignoresSafeArea()
        }
    }

    // MARK: - Artwork background

    @ViewBuilder
    private var artworkBackground: some View {
        if let path = game.artworkPath, let uiImage = ImageCache.shared.image(for: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(Overlay.medium))
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}
