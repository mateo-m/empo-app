import SwiftUI

struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    var appState: AppState
    let onPlay: () -> Void
    /// Optional "Select" action that pre-seeds selection mode with
    /// this game. nil hides the row (e.g. while the library is
    /// already in selection mode, where the entry would be a no-op).
    let onSelect: (() -> Void)?
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

            if let onSelect {
                Divider()
                Button(action: onSelect) {
                    Label("Select", systemImage: "checklist")
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
    func gameContextMenu(
        game: GameEntry,
        appState: AppState,
        onPlay: @escaping () -> Void,
        onSelect: (() -> Void)? = nil,
        gameToDelete: Binding<GameEntry?>,
        showDeleteConfirm: Binding<Bool>,
        gameForSettings: Binding<GameEntry?>,
        gameForInfo: Binding<GameEntry?>
    ) -> some View {
        modifier(
            GameContextMenuModifier(
                game: game,
                appState: appState,
                onPlay: onPlay,
                onSelect: onSelect,
                gameToDelete: gameToDelete,
                showDeleteConfirm: showDeleteConfirm,
                gameForSettings: gameForSettings,
                gameForInfo: gameForInfo
            ))
    }
}
