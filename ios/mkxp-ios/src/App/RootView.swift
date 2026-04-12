import SwiftUI

/// The top-level view that switches between Library and Player based on AppState.
///
/// Library is always mounted so the NavigationStack persists across phases.
/// This lets the reverse hero zoom play when quitting a game. Hidden via
/// opacity during gameplay so the transparent PlayerView shows SDL beneath.
struct RootView: View {
    var appState = AppState.shared
    var layout = ControlsLayout.shared
    @Namespace private var hero

    var body: some View {
        ZStack {
            // Library — always mounted, hidden during gameplay
            GameLibraryView(appState: appState, heroNamespace: hero)
                .opacity(appState.phase == .playing ? 0 : 1)
                .allowsHitTesting(appState.phase != .playing)

            // Playing — transparent controls overlay
            if appState.phase == .playing {
                PlayerView(appState: appState, layout: layout)
                    .zIndex(1)
            }
        }
        .fontDesign(.rounded)
        .tint(.orange)
    }
}
