// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct MidiSoundSetRow: View {
    @State private var current = MidiSoundSet.current
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("MIDI sound set")
                    Text(
                        "Plays music in older games. For the Windows sound, import gm.dls from a Windows PC."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(current?.deletingPathExtension().lastPathComponent ?? String(localized: "Built-in"))
                    .foregroundStyle(.secondary)
            }
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
