import SwiftUI

/// The top-level view that switches between Library and Player based on AppState.
struct RootView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var layout = ControlsLayout.shared

    var body: some View {
        ZStack {
            switch appState.phase {
            case .library, .quitting:
                GameLibraryView(appState: appState)
                    .transition(.opacity)
                    .zIndex(2)

            case .loading:
                // Black background with loading spinner
                LoadingView()
                    .transition(.opacity)
                    .zIndex(1)

            case .playing:
                // Transparent overlay with touch controls
                PlayerView(appState: appState, layout: layout)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.phase)
    }
}

// ============================================================================
// MARK: - Loading View
// ============================================================================

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)

                Text("Loading\u{2026}")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}
