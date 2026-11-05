// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct MidiSoundSetRow: View {
    private enum Choice: Hashable {
        case builtIn, imported, importNew
    }

    @State private var current = MidiSoundSet.current
    @State private var isImporting = false
    @State private var importFailed = false

    private var choice: Binding<Choice> {
        Binding {
            current == nil ? .builtIn : .imported
        } set: { choice in
            switch choice {
            case .builtIn:
                try? MidiSoundSet.removeImported()
                current = MidiSoundSet.current
            case .imported:
                break
            case .importNew:
                isImporting = true
            }
        }
    }

    var body: some View {
        // Under RootView's `.fontDesign(.rounded)`, only `Font.monospaced()` stays fixed-width.
        let fileName = Text(verbatim: "gm.dls").font(.footnote.monospaced())
        SettingsPicker(
            title: "MIDI sound set",
            selection: choice,
            description: Text(
                "Plays music in older games. For the Windows sound, import \(fileName) from a Windows PC."
            )
        ) {
            Text("Built-in").tag(Choice.builtIn)
            if let current {
                Text(current.deletingPathExtension().lastPathComponent).tag(Choice.imported)
            }
            Divider()
            Text("Import Sound Set…").tag(Choice.importNew)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: MidiSoundSet.contentTypes) { result in
            do {
                try MidiSoundSet.replace(with: result.get())
            } catch {
                NSLog("[MidiSoundSet] Import failed: %@", "\(error)")
                importFailed = true
            }
            current = MidiSoundSet.current
        }
        .alert("Can't use this file", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pick a SoundFont (.sf2) or a DLS file (.dls).")
        }
    }
}
