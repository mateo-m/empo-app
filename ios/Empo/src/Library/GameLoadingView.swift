import SwiftUI

struct GameLoadingView: View {
    enum Mode { case loading, resuming }

    let game: GameEntry
    @Environment(\.appState) private var appState
    @Environment(\.engineState) private var engineState
    @Environment(\.pauseManager) private var pauseManager

    private var mode: Mode { pauseManager.pauseSnapshot != nil ? .resuming : .loading }

    @State private var titleVisible = false
    @State private var spinnerVisible = false
    @State private var kenBurns = false
    @State private var appearedAt: ContinuousClock.Instant?

    /// Slight zoom-in that kicks in when the engine finishes loading.
    /// Stacks on top of the slow Ken Burns pan and hints that the
    /// handoff to live gameplay is imminent.
    @State private var readyZoom = false
    private static let readyZoomScale: CGFloat = 1.08

    /// Escape hatch while loading: after a short delay a
    /// Cancel button is revealed so the user can bail if a game hangs during
    /// boot (common with broken Win32 DLL dependencies or bad scripts).
    @State private var cancelVisible = false
    private static let cancelAppearDelay: Duration = .seconds(2)

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
                    .heroTitleShadow()
                    .opacity(titleVisible ? 1 : 0)
                    .offset(y: titleVisible ? 0 : 12)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
                    .accessibilityLabel("Loading game")
                    .opacity(spinnerVisible ? 1 : 0)
                    .offset(y: spinnerVisible ? 0 : 12)
            }
        }
        .overlay(alignment: .bottom) {
            // Using `.overlay` instead of `.safeAreaInset` so appearing
            // the button doesn't shrink the ZStack's content box. The
            // aspect-fill artwork behind would otherwise recompute its
            // frame and pan visibly when the button fades in.
            cancelButton
        }
        .onAppear {
            appearedAt = .now
            withAnimation(Motion.standard.delay(0.2)) {
                titleVisible = true
            }
            withAnimation(Motion.standard.delay(0.28)) {
                spinnerVisible = true
            }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: true)) {
                kenBurns = true
            }
        }
        .task {
            try? await Task.sleep(for: Self.cancelAppearDelay)
            withAnimation(Motion.gentle) {
                cancelVisible = true
            }
        }
        .onChange(of: appState.engineReady) { _, ready in
            guard ready else { return }
            // Slow zoom-in as a visual cue that the game is imminent.
            // Runs independently from the phase transition below so it
            // starts immediately and plays through the handoff.
            withAnimation(.spring(duration: 0.8, bounce: 0.0)) {
                readyZoom = true
            }
            let elapsed = appearedAt.map { ContinuousClock.now - $0 } ?? .seconds(1)
            let t = min(elapsed / .seconds(1), 1.0)
            let duration = 0.15 + t * 0.15
            withAnimation(.spring(duration: duration, bounce: 0)) {
                appState.phase = .playing
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        if cancelVisible {
            Button("Quit to library") {
                // During loading the RGSS thread may not have reached a
                // yield point yet (scripts running back-to-back don't
                // call Graphics.update/Input.update), so the normal
                // terminate request can sit unprocessed. returnToLibrary
                // arms the standard 3s watchdog (alert -> user OK ->
                // exit) but on the loading view forcing the user to read
                // an alert on top of being stuck is bad UX. Also
                // arm a 5s hard-deadline force-quit so the app closes
                // cleanly even if the engine never ack's.
                appState.returnToLibrary()
                appState.armLoadingEscapeForceQuit()
            }
            .buttonStyle(.secondary(size: .md, tint: .white))
            .padding(.bottom, Spacing.xl)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    // The SDL window can't participate in SwiftUI transitions, so
    // the pause snapshot is placed as a static double at the exact
    // gameRect position. Once the hero animation finishes, AppState
    // flips to .playing and live SDL rendering takes over.
    @ViewBuilder
    private var resumeContent: some View {
        if let snapshot = pauseManager.pauseSnapshot {
            PauseSnapshotOverlay(snapshot: snapshot, rect: engineState.gameRect)
                .ignoresSafeArea()
        }
    }


    @ViewBuilder
    private var artworkBackground: some View {
        if let path = game.artworkPath, let uiImage = ImageCache.shared.image(for: path) {
            let kenBurnsScale: CGFloat = kenBurns ? 1.15 : 1.05
            let finalScale = kenBurnsScale * (readyZoom ? Self.readyZoomScale : 1)
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(finalScale)
                .offset(x: kenBurns ? 10 : -10, y: kenBurns ? -8 : 8)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(Scrim.medium))
        } else {
            // No artwork: fall through to the unified placeholder
            // (gradient + gamecontroller glyph) used everywhere else
            // in the library. Skip the Ken Burns / blur path - those
            // are tuned for photographic artwork and would muddy the
            // already-soft gradient. A scrim still goes on top so the
            // foreground title text retains contrast.
            ZStack {
                GameArtworkView(
                    artworkPath: nil,
                    placeholderIconSize: 96,
                    shimmer: false
                )
                Color.black.opacity(Scrim.medium)
            }
            .ignoresSafeArea()
        }
    }
}
