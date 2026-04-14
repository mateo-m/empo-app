import SwiftUI

// MARK: - Game Context Menu

struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    var appState: AppState
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?

    private var isPaused: Bool { appState.pausedGame?.id == game.id }

    func body(content: Content) -> some View {
        content.contextMenu {
            if case .ready = game.status {
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

            if isPaused {
                Divider()

                Button(role: .destructive) {
                    appState.returnToLibrary()
                } label: {
                    Label("Quit", systemImage: "stop.fill")
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
    func gameContextMenu(game: GameEntry, appState: AppState, gameToDelete: Binding<GameEntry?>, showDeleteConfirm: Binding<Bool>, gameForSettings: Binding<GameEntry?>, gameForInfo: Binding<GameEntry?>) -> some View {
        modifier(GameContextMenuModifier(game: game, appState: appState, gameToDelete: gameToDelete, showDeleteConfirm: showDeleteConfirm, gameForSettings: gameForSettings, gameForInfo: gameForInfo))
    }
}
