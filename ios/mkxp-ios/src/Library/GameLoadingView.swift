import SwiftUI

struct GameLoadingView: View {
    let game: GameEntry
    var appState = AppState.shared
    var engineState = EngineState.shared

    /// True when this view is shown for a resume (not a fresh load).
    private var isResume: Bool { engineState.pauseSnapshot != nil }

    @State private var titleVisible = false
    @State private var spinnerVisible = false
    @State private var kenBurns = false

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
                    .opacity(titleVisible ? 1 : 0)
                    .offset(y: titleVisible ? 0 : 12)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
                    .opacity(spinnerVisible ? 1 : 0)
                    .offset(y: spinnerVisible ? 0 : 12)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0).delay(0.2)) {
                titleVisible = true
            }
            withAnimation(.spring(duration: 0.3, bounce: 0).delay(0.28)) {
                spinnerVisible = true
            }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: true)) {
                kenBurns = true
            }
        }
        .onChange(of: appState.phase) { _, newPhase in
            guard newPhase == .playing else { return }
            withAnimation(.spring(duration: 0.25, bounce: 0)) {
                titleVisible = false
            }
            withAnimation(.spring(duration: 0.25, bounce: 0).delay(0.05)) {
                spinnerVisible = false
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
        if let snapshot = engineState.pauseSnapshot {
            let rect = engineState.gameRect
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
                .scaleEffect(kenBurns ? 1.15 : 1.05)
                .offset(x: kenBurns ? 10 : -10, y: kenBurns ? -8 : 8)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(Overlay.medium))
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}
