import SwiftUI

struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    var appState: AppState
    let onPlay: () -> Void
    /// Cancel an in-flight import. When set and the game is
    /// `.importing`, the menu shows only this action (matching the
    /// stop control on the card/row).
    let onCancelImport: (() -> Void)?
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
            if game.isImporting, let onCancelImport {
                Button(role: .destructive, action: onCancelImport) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                if case .ready = game.status {
                    Button {
                        onPlay()
                    } label: {
                        Label(isPaused ? "Resume" : "Play", systemImage: "play.fill")
                    }

                    // Quit a paused game from the library. The
                    // engine tears the session down and parks in its
                    // session loop; the next launch gets a fresh
                    // Ruby VM instance (cross-session play).
                    if isPaused, CrossSessionPlay.enabled {
                        Button(role: .destructive) {
                            appState.returnToLibrary()
                        } label: {
                            Label("Quit", systemImage: "stop.fill")
                        }
                    }

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
        }
        .tint(nil)
    }
}

extension View {
    func gameContextMenu(
        game: GameEntry,
        appState: AppState,
        onPlay: @escaping () -> Void,
        onCancelImport: (() -> Void)? = nil,
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
                onCancelImport: onCancelImport,
                onSelect: onSelect,
                gameToDelete: gameToDelete,
                showDeleteConfirm: showDeleteConfirm,
                gameForSettings: gameForSettings,
                gameForInfo: gameForInfo
            ))
    }
}
