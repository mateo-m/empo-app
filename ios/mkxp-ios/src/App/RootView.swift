import SwiftUI

/// The top-level view that switches between Library and Player based on AppState.
///
/// Library is always mounted so the NavigationStack persists across phases.
/// This lets the reverse hero zoom play when quitting a game. Hidden via
/// opacity during gameplay so the transparent PlayerView shows SDL beneath.
struct RootView: View {
    private let appState = AppState.shared
    private let engineState = EngineState.shared
    private let layout = ControlsLayout.shared
    @Namespace private var hero
    @State private var showSplash = true
    @State private var splashExiting = false
    @State private var splashDismissed = false

    var body: some View {
        ZStack {
            // Library — always mounted, hidden during gameplay
            GameLibraryView(appState: appState, heroNamespace: hero, splashDismissed: splashDismissed)
                .opacity(appState.phase == .playing ? 0 : 1)
                .allowsHitTesting(appState.phase != .playing)

            // Playing — transparent controls overlay.
            // .transition(.identity) prevents the default fade-in so
            // PlayerView appears at full opacity instantly, even when
            // the phase change is wrapped in withAnimation.  This lets
            // the library fade out smoothly without a cross-fade dim.
            if appState.phase == .playing {
                PlayerView(appState: appState, engineState: engineState, layout: layout)
                    .transition(.identity)
                    .zIndex(1)
            }
        }
        .fontDesign(.rounded)
        .tint(.brand)
        .overlay {
            if showSplash {
                SplashView(exiting: splashExiting)
                    .zIndex(10)
            }
        }
        .onAppear {
            // Hold the splash, then start exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                splashDismissed = true
                withAnimation(.spring(duration: 0.5, bounce: 0)) {
                    splashExiting = true
                } completion: {
                    showSplash = false
                }
            }
        }
        .alert("Something went wrong", isPresented: showErrorAlert) {
            Button("OK") {
                appState.errorMessage = nil
                appState.returnToLibrary()
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if appState.phase == .playing {
                engineState.requestBackgroundPause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            engineState.resumeFromBackground()
        }
    }

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )
    }
}

// MARK: - Splash Screen

private struct SplashView: View {
    let exiting: Bool
    @State private var entered = false
    @Environment(\.colorScheme) private var colorScheme

    private var contentColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack {
            // Background — brand colored, fades out on exit
            Color.brand
                .ignoresSafeArea()
                .opacity(exiting ? 0 : 1)

            VStack(spacing: Spacing.lg) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(contentColor)
                    .blur(radius: exiting ? 10 : 0)
                    .scaleEffect(exiting ? 0.8 : 1)
                    .opacity(exiting ? 0 : 1)

                Text("mkxp-z")
                    .font(.title)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .foregroundStyle(contentColor)
                    .blur(radius: exiting ? 10 : 0)
                    .scaleEffect(exiting ? 0.8 : 1)
                    .opacity(exiting ? 0 : 1)
            }
            .scaleEffect(entered ? 1 : 0.8)
            .opacity(entered ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                entered = true
            }
        }
    }
}
