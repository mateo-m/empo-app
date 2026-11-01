// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LibraryCommands: Commands {
    @FocusedValue(\.libraryWindow) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Games…") { window?.showsImporter = true }
                .keyboardShortcut("o")
                .disabled(window == nil)
        }

        CommandGroup(replacing: .toolbar) {
            ViewModeCommands()
            Divider()
            SortCommands()
        }

        CommandMenu("Game") {
            let game = window?.selectedReadyGame
            Button("Play") { game.map { window?.play($0) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(game == nil)
            Divider()
            Button("Get Info") { window?.showsInspector = true }
                .keyboardShortcut("i")
                .disabled(game == nil)
            Button("Game Settings…") {
                if let game { openWindow(id: GameSettingsWindow.id, value: game.id) }
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
            .disabled(game == nil)
            Button("Show in Finder") { game.map { window?.showInFinder($0) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(game == nil)
            Divider()
            Button("Delete Game…") {
                if let selected = window?.selectedGame { window?.requestDelete(selected) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(window?.selectedGame == nil)
        }
    }
}

private struct ViewModeCommands: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Toggle("as Grid", isOn: isMode(.grid))
            .keyboardShortcut("1")
        Toggle("as List", isOn: isMode(.list))
            .keyboardShortcut("2")
    }

    private func isMode(_ mode: LibraryDisplayMode) -> Binding<Bool> {
        Binding(
            get: { settings.libraryDisplayMode == mode },
            set: { if $0 { settings.libraryDisplayMode = mode } }
        )
    }
}

private struct SortCommands: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Picker("Sort by", selection: $settings.librarySortOption) {
            ForEach(LibrarySortOption.groups) { group in
                Section {
                    ForEach(group.options, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        }
    }
}
