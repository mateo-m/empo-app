import SwiftUI

struct GameLoadingView: View {
    enum Mode { case loading, resuming }

    let game: GameEntry
    var appState = AppState.shared
    var engineState = EngineState.shared
    var pauseManager = PauseManager.shared

    private var mode: Mode { pauseManager.pauseSnapshot != nil ? .resuming : .loading }

    @State private var titleVisible = false
    @State private var spinnerVisible = false
    @State private var kenBurns = false
    @State private var appearedAt: ContinuousClock.Instant?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch mode {
            case .loading:  loadingContent
            case .resuming: resumeContent
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.black, for: .navigation)
    }


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
            appearedAt = .now
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
        .onChange(of: appState.engineReady) { _, ready in
            guard ready else { return }
            let elapsed = appearedAt.map { ContinuousClock.now - $0 } ?? .seconds(1)
            let t = min(elapsed / .seconds(1), 1.0)
            let duration = 0.15 + t * 0.15
            withAnimation(.spring(duration: duration, bounce: 0)) {
                appState.phase = .playing
            }
        }
    }

    //
    // The SDL window can't participate in SwiftUI transitions, so we
    // use the pause snapshot as a static double placed at the exact
    // gameRect position. Once the hero animation finishes, AppState
    // flips to .playing and live SDL rendering takes over.

    @ViewBuilder
    private var resumeContent: some View {
        if let snapshot = pauseManager.pauseSnapshot {
            let rect = engineState.gameRect
            Image(uiImage: snapshot)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .ignoresSafeArea()
        }
    }


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
