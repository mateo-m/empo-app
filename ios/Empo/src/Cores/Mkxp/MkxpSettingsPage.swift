// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct MkxpSettingsPage: View {
    let model: GameSettingsModel
    @Bindable var state: MkxpSettingsState

    var body: some View {
        Group {
            GameplaySettingsSection(model: model)
            DisplaySettingsSection(model: model, fields: [.smoothScaling, .fixedAspectRatio]) {
                renderScaleRow
                fontScaleRow
                MkxpEngineRow(state: state, field: .solidFonts) {
                    SettingsToggle(
                        title: "Solid fonts",
                        isOn: Binding(
                            get: { state.effectiveSolidFonts },
                            set: { state.engine.solidFonts = $0 }
                        ),
                        description:
                            "Draw text as solid pixels, with no soft edges. This looks sharper in some games."
                    )
                }
            }
            #if os(iOS)
            LayoutSettingsSection(model: model)
            #endif
            Section {
                MkxpEngineRow(state: state, field: .frameSkip) {
                    SettingsToggle(
                        title: "Frame skip",
                        isOn: Binding(
                            get: { state.effectiveFrameSkip },
                            set: { state.engine.frameSkip = $0 }
                        ),
                        description:
                            "Skip frames when the game falls behind. The game keeps up better, but motion looks less smooth."
                    )
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("How the engine handles heavy scenes.")
            }
            Section {
                GameMidiSoundSetRow(state: state)
            } header: {
                Text("Music")
            } footer: {
                Text("How the game's music sounds.")
            }
            MkxpEngineSection(model: model, state: state)
        }
        .onChange(of: state.settings) { state.save() }
        .onChange(of: state.engine) { state.save() }
    }

    private var renderScaleRow: some View {
        MkxpEngineRow(state: state, field: .renderScale) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker(
                    "Render scale",
                    selection: Binding(
                        get: { state.effectiveRenderScale },
                        set: { state.engine.renderScale = $0 }
                    )
                ) {
                    ForEach(RenderScale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif

                SettingsDescription(Text(state.effectiveRenderScale.description))
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private var fontScaleRow: some View {
        MkxpEngineRow(state: state, field: .fontScale) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("Font scale")
                    Spacer()
                    Text(
                        verbatim:
                            "\(state.effectiveFontScale.formatted(.number.precision(.fractionLength(1))))x"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { state.effectiveFontScale },
                        set: { state.engine.fontScale = $0 }
                    ),
                    in: 0.5...2.0,
                    step: 0.1
                )
                SettingsDescription(Text("Scale all in-game text. 1.0x is the default size."))
            }
            .padding(.vertical, Spacing.xxs)
        }
    }
}

struct MkxpEngineRow<Content: View>: View {
    let state: MkxpSettingsState
    let field: MkxpEngineField
    @ViewBuilder let content: Content

    var body: some View {
        SettingRow(isChanged: state.engine.isChanged(field)) {
            state.resetField(field)
        } content: {
            content
        }
    }
}

struct GameMidiSoundSetRow: View {
    @Bindable var state: MkxpSettingsState

    var body: some View {
        MidiSoundSetPicker(
            soundSet: .game(state.container),
            defaultSet: defaultSet,
            description: state.gameOwnMidiSoundFont == nil
                ? Text("Default uses the sound set from Settings.")
                : Text("Default uses the game's own sound set."),
            choice: choice,
            imported: $state.gameMidiSoundSet,
            pick: { choice in
                let value: GameMidiSoundSet? =
                    switch choice {
                    case .appSetting: nil
                    case .builtIn: .builtIn
                    case .imported: .imported
                    }
                state.settings.midiSoundSet = value
                // An import can end after the page closed, and the page can open again with a new state
                // in the meantime. So save only this field, on top of the settings on disk.
                var saved = MkxpSettings.load(from: state.container.empoStateURL)
                saved.midiSoundSet = value
                saved.save(to: state.container.empoStateURL)
            }
        )
        // A sheet that opened during the copy holds the old choice.
        .onChange(of: MidiSoundSetCopies.shared.finishedCopies(into: .game(state.container))) {
            state.settings.midiSoundSet = MkxpSettings.load(from: state.container.empoStateURL).midiSoundSet
        }
    }

    private var choice: MidiSoundSetPicker.Choice {
        switch state.settings.midiSoundSet {
        case .builtIn: .builtIn
        case .imported where state.gameMidiSoundSet != nil: .imported
        case .imported, nil: .appSetting
        }
    }

    private var defaultSet: MidiSoundSetPicker.DefaultSet {
        if let own = state.gameOwnMidiSoundFont {
            return .init(
                name: URL(fileURLWithPath: own).deletingPathExtension().lastPathComponent, source: .game)
        }
        if let app = MidiSoundSet.app.current {
            return .init(name: app.deletingPathExtension().lastPathComponent, source: .imported)
        }
        return .init(name: MidiSoundSet.builtInName ?? String(localized: "Built-in"), source: .bundled)
    }
}
