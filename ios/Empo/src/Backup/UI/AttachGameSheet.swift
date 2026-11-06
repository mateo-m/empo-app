import GameProbe
import SwiftUI

/// The attach of SPEC 11.11: the user names the game a snapshot
/// restores into.
///
/// The alias lands in the chosen game's `EmpoState/`, so the next
/// snapshot of that game matches on its own and this sheet never
/// opens again for it.
struct AttachGameSheet: View {

    let snapshot: SnapshotIdentity
    /// Runs after the attach, with the game the user chose.
    let attached: (GameContainer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: GameContainer?
    @State private var failedGame: GameContainer?

    private let games: [GameContainer]
    private let names: [String: String]

    init(snapshot: SnapshotIdentity, attached: @escaping (GameContainer) -> Void) {
        self.snapshot = snapshot
        self.attached = attached
        games = GameContainer.discover().sorted { $0.folderName < $1.folderName }
        names = Dictionary(
            uniqueKeysWithValues: games.map { ($0.folderName, BackupGameNames.name(of: $0)) })
    }

    var body: some View {
        StandardSheet(
            title: AttachAction.pickTitle,
            barAction: SheetBarAction(AttachAction.cancelLabel) { dismiss() }
        ) {
            SheetBodyText(
                AttachAction.pickBody(snapshotName: snapshot.containerFolderName))
            SheetCard {
                ForEach(Array(games.enumerated()), id: \.element) { index, game in
                    if index > 0 {
                        SheetRowSeparator()
                    }
                    Button {
                        chosen = game
                    } label: {
                        HStack(spacing: Spacing.md) {
                            BackupGameArtwork(
                                gameKey: BackupKeys.gameKey(containerFolderName: game.folderName))
                            Text(name(of: game))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.lg)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .alert(
            AttachAction.confirmTitle(targetGameName: name(of: chosen)),
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })
        ) {
            Button(AttachAction.cancelLabel, role: .cancel) { chosen = nil }
            Button(AttachAction.confirmLabel(targetGameName: name(of: chosen))) { attach() }
        } message: {
            Text(AttachAction.confirmBody(targetGameName: name(of: chosen)))
        }
        .alert(
            AttachAction.failedTitle(targetGameName: name(of: failedGame)),
            isPresented: Binding(
                get: { failedGame != nil }, set: { if !$0 { failedGame = nil } })
        ) {
            Button(AttachAction.failedDismissLabel) { failedGame = nil }
        } message: {
            Text(AttachAction.failedBody)
        }
    }

    private func name(of game: GameContainer?) -> String {
        guard let game else { return "" }
        return names[game.folderName] ?? game.folderName
    }

    private func attach() {
        guard let game = chosen else { return }
        chosen = nil
        // The restore finds its game through the alias, so a restore
        // with no saved alias would have no game to go into.
        do {
            try GameIdentities.attach(snapshot, to: game)
        } catch {
            failedGame = game
            return
        }
        dismiss()
        attached(game)
    }
}
