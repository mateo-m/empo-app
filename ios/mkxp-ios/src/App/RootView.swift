import SwiftUI

// MARK: - Theme

extension Color {
    /// The app's primary brand color.
    static let brand = Color.orange
}

extension ShapeStyle where Self == Color {
    /// The app's primary brand color (available in ShapeStyle contexts).
    static var brand: Color { .orange }
}

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
        .alert("Something went wrong", isPresented: showErrorAlert) {
            Button("OK") {
                appState.errorMessage = nil
                appState.returnToLibrary()
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )
    }
}
