// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct DeleteGameAlerts: ViewModifier {
    @Binding var isPresented: Bool
    let game: GameEntry?
    @Binding var saveRescueFailures: [GameEntry]
    let onDelete: (GameEntry) -> Void
    let onDeleteDiscardingSaves: (GameEntry) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Delete this game?", isPresented: $isPresented, presenting: game) { game in
                #if os(macOS)
                Button("Delete") { onDelete(game) }
                #else
                Button("Delete", role: .destructive) { onDelete(game) }
                    .keyboardShortcut(.defaultAction)
                #endif
                Button("Cancel", role: .cancel) {}
            } message: { game in
                if game.isImporting {
                    // For an update, the installed game stays, so the
                    // text must not promise to remove files.
                    Text(
                        "This stops importing \"\(game.title)\". If you were updating a game you already have, that copy stays as it is."
                    )
                } else {
                    #if os(macOS)
                    Text(
                        "This deletes \"\(game.title)\" from this Mac. Empo moves the saves it recognizes to Rescued Saves. Saves it doesn't recognize are deleted with the game. You can't undo this."
                    )
                    #else
                    Text(
                        "This deletes \"\(game.title)\" from your device. Empo moves the saves it recognizes to Rescued Saves. Saves it doesn't recognize are deleted with the game. You can't undo this."
                    )
                    #endif
                }
            }
            .alert(
                "Couldn't move the saves",
                isPresented: Binding(
                    get: { !saveRescueFailures.isEmpty },
                    set: { presented in
                        // Dismissal pops the queue. The binding then
                        // reads true again while more failures wait,
                        // so the next game's choice presents in turn.
                        if !presented, !saveRescueFailures.isEmpty {
                            saveRescueFailures.removeFirst()
                        }
                    }
                ),
                presenting: saveRescueFailures.first
            ) { game in
                #if os(macOS)
                Button("Delete Anyway", role: .destructive) { onDeleteDiscardingSaves(game) }
                Button("Keep Game", role: .cancel) {}
                #else
                Button("Delete anyway", role: .destructive) { onDeleteDiscardingSaves(game) }
                Button("Keep game", role: .cancel) {}
                #endif
            } message: { game in
                Text(
                    "Empo couldn't move the saves for \"\(game.title)\" to Rescued Saves. Free up space and delete again, or delete now and lose those saves. You can't undo this."
                )
            }
    }
}

/// Button actions run before SwiftUI resets the binding, and the
/// pipeline consumes the prompt in the action, so the later
/// set-to-nil falls through to a guarded no-op.
struct ImportReplaceAlert: ViewModifier {
    @Binding var prompt: ImportReplacePrompt?
    let onReplace: () -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { prompt != nil },
                set: { presented in if !presented { prompt = nil } }
            ),
            presenting: prompt
        ) { _ in
            Button("Update", role: .destructive, action: onReplace)
            Button("Cancel", role: .cancel, action: onCancel)
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

struct StopValidationAlert: ViewModifier {
    @Binding var isPresented: Bool
    let onStop: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.alert("Stop Import?", isPresented: $isPresented) {
            Button("Keep Importing", role: .cancel) {}
            Button("Stop Import", action: onStop)
        } message: {
            message
        }
        #else
        content.alert("Stop import?", isPresented: $isPresented) {
            Button("Keep importing", role: .cancel) {}
            Button("Stop import", role: .destructive, action: onStop)
        } message: {
            message
        }
        #endif
    }

    private var message: Text {
        Text("Empo is still checking this game. If you stop now, Empo won't import it.")
    }
}

struct InvalidGameAlert: ViewModifier {
    @Binding var reason: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.alert("This game won't open.", isPresented: isPresented, presenting: reason) { _ in
            Button("OK") {}
        } message: { reason in
            Text(reason)
        }
        #else
        content.alert("This game won't open", isPresented: isPresented, presenting: reason) { _ in
            Button("Got it") { reason = nil }
        } message: { reason in
            Text(reason)
        }
        #endif
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { reason != nil }, set: { presented in if !presented { reason = nil } })
    }
}
