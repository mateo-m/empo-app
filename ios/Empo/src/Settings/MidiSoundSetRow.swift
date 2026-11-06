// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct MidiSoundSetRow: View {
    @State private var imported = MidiSoundSet.app.current

    var body: some View {
        // Under RootView's `.fontDesign(.rounded)`, only `Font.monospaced()` stays fixed-width.
        let fileName = Text(verbatim: "gm.dls").font(.footnote.monospaced())
        MidiSoundSetPicker(
            soundSet: .app,
            appSettingLabel: nil,
            description: Text(
                "Plays music in older games. For the Windows sound, import \(fileName) from a Windows PC."
            ),
            choice: imported == nil ? .builtIn : .imported,
            imported: $imported,
            pick: { _ in }
        )
    }
}

struct MidiSoundSetPicker: View {
    enum Choice: Hashable {
        case appSetting, builtIn, imported
    }

    private enum Option: Hashable {
        case choice(Choice)
        case importNew
    }

    let soundSet: MidiSoundSet
    /// The option that follows the app settings. nil hides it.
    let appSettingLabel: Text?
    let description: Text
    let choice: Choice
    @Binding var imported: URL?
    let pick: (Choice) -> Void

    @State private var isImporting = false
    @State private var formatFailed = false
    @State private var copyFailure: String?

    private var isCopying: Bool { MidiSoundSetCopies.shared.isCopying(into: soundSet) }

    private var selection: Binding<Option> {
        Binding {
            .choice(choice)
        } set: { option in
            switch option {
            case .choice(.imported):
                break
            case .choice(let choice):
                try? soundSet.removeImported()
                imported = soundSet.current
                pick(choice)
            case .importNew:
                isImporting = true
            }
        }
    }

    var body: some View {
        SettingsPicker(title: "MIDI sound set", selection: selection, description: description) {
            if let appSettingLabel {
                appSettingLabel.tag(Option.choice(.appSetting))
            }
            Text("Built-in").tag(Option.choice(.builtIn))
            if let imported {
                Text(imported.deletingPathExtension().lastPathComponent).tag(Option.choice(.imported))
            }
            Divider()
            Text("Import Sound Set…").tag(Option.importNew)
        }
        .disabled(isCopying)
        // The copy can end after this sheet closed and opened again.
        .onChange(of: isCopying) { imported = soundSet.current }
        #if os(iOS)
        .sheet(isPresented: $isImporting) {
            DocumentPickerView(contentTypes: MidiSoundSet.contentTypes, allowsMultipleSelection: false) {
                urls in
                importSoundSet(urls[0])
            }
        }
        #else
        .fileImporter(isPresented: $isImporting, allowedContentTypes: MidiSoundSet.contentTypes) { result in
            switch result {
            case .success(let url):
                importSoundSet(url)
            case .failure(let error):
                NSLog("[MidiSoundSet] Import failed: %@", "\(error)")
                copyFailure = error.localizedDescription
            }
        }
        #endif
        .alert("Can't use this file", isPresented: $formatFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pick a SoundFont (.sf2) or a DLS file (.dls).")
        }
        .alert(
            "Couldn't import the sound set",
            isPresented: Binding {
                copyFailure != nil
            } set: {
                if !$0 { copyFailure = nil }
            },
            presenting: copyFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func importSoundSet(_ url: URL) {
        MidiSoundSetCopies.shared.begin(soundSet)
        Task {
            do {
                try await Task.detached { [soundSet] in try soundSet.replace(with: url) }.value
                pick(.imported)
            } catch MidiSoundSet.ImportError.notASoundSet {
                formatFailed = true
            } catch {
                NSLog("[MidiSoundSet] Import failed: %@", "\(error)")
                copyFailure = error.localizedDescription
            }
            MidiSoundSetCopies.shared.end(soundSet)
        }
    }
}
