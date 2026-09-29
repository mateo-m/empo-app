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
            LayoutSettingsSection(model: model)
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
                .pickerStyle(.navigationLink)

                Text(
                    state.effectiveRenderScale.description
                        + " The game's size and layout stay the same, only sharper."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    Text(String(format: "%.1fx", state.effectiveFontScale))
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
                Text("Scale all in-game text. 1.0x is the default size.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
