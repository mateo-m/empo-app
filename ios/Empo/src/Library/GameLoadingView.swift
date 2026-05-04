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
    private static let cancelAppearDelay: Duration = .seconds(7)

    /// Looked up at body-time so the loading view shares the same
    /// source image as the Game Info sheet's banner. By design
    /// banner == loading-view backdrop (just darker + blurred), so
    /// banner-less games show the placeholder on both surfaces and
    /// banner-having games see their banner in both places.
    private var bannerImage: UIImage? {
        guard let container = game.container,
              let path = GameMetadata.load(from: container)
                .customBannerPath(in: container) else { return nil }
        return ImageCache.shared.image(for: path)
    }

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
            bannerBackground

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
            // Previously a "Quit to library" button that called
            // returnToLibrary + a hard-deadline force-quit helper.
            // Replaced with a static label because:
            //
            // 1. returnToLibrary triggers the cross-session Ruby
            //    state cleanup machinery, which we no longer trust
            //    after parking the mruby experiment (see
            //    MRUBY_POSTMORTEM.md). Lingering state from a hung
            //    game would leak into the next session.
            // 2. The force-quit helper called the system exit
            //    function, which violates App Store guideline 2.5.1
            //    ("Apps should not terminate themselves
            //    programmatically"). That helper has been removed
            //    entirely. See QUIT_PATHS_DISABLED.md.
            //
            // The label below tells the user to close Empo from the
            // app switcher, which is the iOS-sanctioned way to
            // force-close. Same pattern RootView uses for
            // engineHung errors.
            Text("If loading is stuck, close Empo from the app switcher and reopen.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
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
    private var bannerBackground: some View {
        if let banner = bannerImage {
            let kenBurnsScale: CGFloat = kenBurns ? 1.15 : 1.05
            let finalScale = kenBurnsScale * (readyZoom ? Self.readyZoomScale : 1)
            // No explicit `.frame` here: `.aspectRatio(.fill)` on a
            // resizable image inside a ZStack already proposes the
            // parent's full size. `.clipped()` would tame overflow
            // but would also create a separate raster that breaks
            // the subsequent `.blur` (the blur kernel sees a hard
            // edge instead of the overflowing pixels and visibly
            // desaturates).
            Image(uiImage: banner)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(finalScale)
                .offset(x: kenBurns ? 10 : -10, y: kenBurns ? -8 : 8)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(Scrim.medium))
        } else {
            // No banner: fall through to the unified placeholder
            // (gradient + gamecontroller glyph). The Game Info
            // sheet's banner uses the same fallback so the two
            // surfaces match - this view just blurs + darkens the
            // result. Skip the Ken Burns / blur path here because
            // the placeholder gradient is already soft and a blur
            // would just muddy it. A scrim still goes on top so
            // the foreground title text retains contrast.
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
