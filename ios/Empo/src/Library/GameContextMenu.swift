import SwiftUI


struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    var appState: AppState
    let onPlay: () -> Void
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?
    @Environment(\.pauseManager) private var pauseManager

    private var isPaused: Bool { pauseManager.pausedGame?.id == game.id }

    func body(content: Content) -> some View {
        content.contextMenu {
            if case .ready = game.status {
                Button {
                    onPlay()
                } label: {
                    Label(isPaused ? "Resume" : "Play", systemImage: "play.fill")
                }

                // Context-menu Quit disabled until cross-session
                // Ruby state cleanup is reliable. See
                // ExperimentalFeature comment in AppSettings.swift.
                // if isPaused {
                //     Button(role: .destructive) {
                //         appState.returnToLibrary()
                //     } label: {
                //         Label("Quit", systemImage: "stop.fill")
                //     }
                // }

                Divider()

                Button {
                    gameForInfo = game
                } label: {
                    Label("Info", systemImage: "info.circle")
                }

                Button {
                    gameForSettings = game
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            Divider()

            Button(role: .destructive) {
                gameToDelete = game
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .tint(nil)
    }
}

extension View {
    func gameContextMenu(game: GameEntry,
                         appState: AppState,
                         onPlay: @escaping () -> Void,
                         gameToDelete: Binding<GameEntry?>,
                         showDeleteConfirm: Binding<Bool>,
                         gameForSettings: Binding<GameEntry?>,
                         gameForInfo: Binding<GameEntry?>) -> some View {
        modifier(GameContextMenuModifier(
            game: game,
            appState: appState,
            onPlay: onPlay,
            gameToDelete: gameToDelete,
            showDeleteConfirm: showDeleteConfirm,
            gameForSettings: gameForSettings,
            gameForInfo: gameForInfo
        ))
    }
}
