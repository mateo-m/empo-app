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
            defaultSet: nil,
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

    enum Source {
        case game, imported, bundled

        var symbol: String {
            switch self {
            case .game: "gamecontroller"
            case .imported: "square.and.arrow.down"
            case .bundled: "shippingbox"
            }
        }

        var name: Text {
            switch self {
            case .game:
                Text("From the game", comment: "Where a MIDI sound set comes from. Read by VoiceOver.")
            case .imported:
                Text(
                    "Imported",
                    comment:
                        "Where a MIDI sound set comes from. Read by VoiceOver, and the title of the menu part with imported sound sets."
                )
            case .bundled:
                Text("Comes with Empo", comment: "Where a MIDI sound set comes from. Read by VoiceOver.")
            }
        }
    }

    struct DefaultSet {
        let name: String
        let source: Source
    }

    private enum Option: Hashable {
        case choice(Choice)
        case importNew
    }

    let soundSet: MidiSoundSet
    /// The set that "Default" plays. nil hides "Default".
    let defaultSet: DefaultSet?
    let description: Text
    let choice: Choice
    @Binding var imported: URL?
    let pick: (Choice) -> Void

    @State private var isImporting = false

    @ViewBuilder private var menuItems: some View {
        // On iOS, a menu drops the accessibility label of an item in a Section.
        if let defaultSet {
            item(.appSetting, "Default", subtitle: defaultSet.name, source: defaultSet.source)
            Divider()
        }
        item(.builtIn, "Built-in", subtitle: MidiSoundSet.builtInName, source: .bundled)
        if let imported {
            Section {
                item(
                    .imported, "\(imported.deletingPathExtension().lastPathComponent)", subtitle: nil,
                    source: nil)
            } header: {
                Source.imported.name
            }
        }
        Section {
            Button("Import Sound Set…") { selection.wrappedValue = .importNew }
        }
    }

    private var currentTitle: LocalizedStringKey {
        switch choice {
        case .appSetting: "Default"
        case .builtIn: "Built-in"
        case .imported: "\(imported?.deletingPathExtension().lastPathComponent ?? "")"
        }
    }

    // A menu shows the second Text of a toggle as a dimmed line under the first.
    // On iOS it shows an Image as an icon. On macOS it drops that Image when the
    // item has a second line, so the icon goes inside the title. An icon there
    // that is shorter than the text, such as `gamecontroller` at body size,
    // makes macOS drop the second line too.
    // An item without a source sits under a section title that names it.
    private func item(
        _ option: Choice, _ title: LocalizedStringKey, subtitle: String?, source: Source?
    ) -> some View {
        Toggle(
            isOn: Binding {
                choice == option
            } set: { _ in
                selection.wrappedValue = .choice(option)
            }
        ) {
            #if os(macOS)
            if let source {
                Text(
                    "\(Text(title))  \(Text(Image(systemName: source.symbol)).font(.title3).foregroundStyle(.secondary))"
                )
            } else {
                Text(title)
            }
            #else
            Text(title)
            #endif
            if let subtitle {
                Text(subtitle)
            }
            #if os(iOS)
            if let source {
                Image(systemName: source.symbol)
            }
            #endif
        }
        // A menu item drops the label of its icon.
        .accessibilityLabel(
            [subtitle.map { Text($0) }, source?.name].compactMap(\.self)
                .reduce(Text(title)) { Text("\($0), \($1)") })
    }

    private var failure: MidiSoundSetCopies.Failure? { MidiSoundSetCopies.shared.failure(of: soundSet) }

    private func failureBinding(_ matches: @escaping (MidiSoundSetCopies.Failure) -> Bool) -> Binding<Bool> {
        Binding {
            failure.map(matches) ?? false
        } set: {
            if !$0 { MidiSoundSetCopies.shared.failures[soundSet.folderURL] = nil }
        }
    }

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
                MidiSoundSetCopies.shared.removed(soundSet)
                imported = soundSet.current
                pick(choice)
            case .importNew:
                isImporting = true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            #if os(iOS)
            Menu {
                menuItems
            } label: {
                HStack {
                    Text("MIDI sound set").foregroundStyle(Color.primary)
                    Spacer()
                    Text(currentTitle)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            #else
            LabeledContent("MIDI sound set") {
                Menu {
                    menuItems
                } label: {
                    Text(currentTitle)
                }
                .fixedSize()
            }
            #endif
            SettingsDescription(description)
        }
        .padding(.vertical, Spacing.xxs)
        .disabled(isCopying)
        // The copy can end after this sheet closed and opened again.
        .onChange(of: MidiSoundSetCopies.shared.revision(of: soundSet)) {
            imported = soundSet.current
        }
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
                MidiSoundSetCopies.shared.failures[soundSet.folderURL] = .copy(error.localizedDescription)
            }
        }
        #endif
        .alert("Can't use this file", isPresented: failureBinding { $0 == .notASoundSet }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pick a SoundFont (.sf2) or a DLS file (.dls).")
        }
        .alert(
            "Couldn't import the sound set",
            isPresented: failureBinding {
                if case .copy = $0 { true } else { false }
            },
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            if case .copy(let message) = failure { Text(message) }
        }
    }

    private func importSoundSet(_ url: URL) {
        MidiSoundSetCopies.shared.begin(soundSet)
        Task {
            var failure: MidiSoundSetCopies.Failure?
            do {
                try await Task.detached { [soundSet] in try soundSet.replace(with: url) }.value
                pick(.imported)
            } catch MidiSoundSet.ImportError.notASoundSet {
                failure = .notASoundSet
            } catch {
                NSLog("[MidiSoundSet] Import failed: %@", "\(error)")
                failure = .copy(error.localizedDescription)
            }
            MidiSoundSetCopies.shared.end(soundSet, failure: failure)
        }
    }
}
