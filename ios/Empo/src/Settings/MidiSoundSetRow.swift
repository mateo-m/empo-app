// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct MidiSoundSetRow: View {
    @State private var current = MidiSoundSet.current
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            LabeledContent("MIDI sound set") {
                Text(current?.deletingPathExtension().lastPathComponent ?? String(localized: "Built-in"))
            }
            Text(
                "Older games play their music with this sound set. To hear them as on Windows, import gm.dls from C:\\Windows\\System32\\drivers on a Windows PC."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Button("Import Sound Set…") { isImporting = true }
                if current != nil {
                    Button("Use Built-in") {
                        try? MidiSoundSet.removeImported()
                        current = MidiSoundSet.current
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, Spacing.xxs)
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
            Text("Pick a SoundFont (.sf2 or .sf3) or a DLS file (.dls).")
        }
    }
}
