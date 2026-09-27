import GameProbe
import SwiftUI

// The sections and rows of the Game Settings sheet that more than one
// core shows. Each core puts its page together from these in
// `settingsPage(_:)`.

struct GameplaySettingsSection: View {
    let model: GameSettingsModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsToggle(
                    title: "Fast forward",
                    isOn: Binding(
                        get: { model.fastForwardEnabled },
                        set: { on in
                            // A stale 1x from the old single-slider UI
                            // counts as no value.
                            if on {
                                if (model.settings.speedMultiplier ?? 0) < 2 {
                                    model.settings.speedMultiplier = 4
                                }
                            } else {
                                model.settings.speedMultiplier = nil
                            }
                        }
                    ),
                    description:
                        "Add a Fast forward button to the in-game menu. While it is on, the game runs at the speed below."
                )

                if model.fastForwardEnabled {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(model.effectiveSpeedMultiplier)x")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.effectiveSpeedMultiplier) },
                            set: { model.settings.speedMultiplier = Int($0) }
                        ),
                        in: 2...9,
                        step: 1
                    )
                }
            }
            .padding(.vertical, Spacing.xxs)
        } header: {
            Text("Gameplay")
        } footer: {
            Text("How you play the game.")
        }
    }
}

/// The display rows of `fields`, in that order.
struct DisplaySettingsSection: View {
    let model: GameSettingsModel
    let fields: [MkxpEngineField]

    var body: some View {
        Section {
            if model.engineSettings.gameDefaultsUnknown {
                Text(
                    "Empo can't read this game's own settings, so the values below start from Empo's defaults."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(fields, id: \.self) { field in
                row(field)
            }
        } header: {
            Text("Display")
        } footer: {
            Text("How the game looks on screen.")
        }
    }

    @ViewBuilder
    private func row(_ field: MkxpEngineField) -> some View {
        switch field {
        case .smoothScaling:
            EngineFieldRow(model: model, field: field) {
                SettingsToggle(
                    title: "Smooth scaling",
                    isOn: Binding(
                        get: { model.effectiveSmoothScaling },
                        set: { model.engineSettings.smoothScaling = $0 }
                    ),
                    description:
                        "Smooth the picture when the game scales up. Turn it off to keep the pixels crisp."
                )
            }
        case .fixedAspectRatio:
            EngineFieldRow(model: model, field: field) {
                SettingsToggle(
                    title: "Fixed aspect ratio",
                    isOn: Binding(
                        get: { model.effectiveFixedAspectRatio },
                        set: { model.engineSettings.fixedAspectRatio = $0 }
                    ),
                    description:
                        "Preserve the game's proportions instead of stretching to fill the screen."
                )
            }
        case .renderScale:
            EngineFieldRow(model: model, field: field) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Picker(
                        "Render scale",
                        selection: Binding(
                            get: { model.effectiveRenderScale },
                            set: { model.engineSettings.renderScale = $0 }
                        )
                    ) {
                        ForEach(RenderScale.allCases, id: \.self) { scale in
                            Text(scale.label).tag(scale)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Text(
                        model.effectiveRenderScale.description
                            + " The game's size and layout stay the same, only sharper."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        case .fontScale:
            EngineFieldRow(model: model, field: field) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack {
                        Text("Font scale")
                        Spacer()
                        Text(String(format: "%.1fx", model.effectiveFontScale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { model.effectiveFontScale },
                            set: { model.engineSettings.fontScale = $0 }
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
        case .solidFonts:
            EngineFieldRow(model: model, field: field) {
                SettingsToggle(
                    title: "Solid fonts",
                    isOn: Binding(
                        get: { model.effectiveSolidFonts },
                        set: { model.engineSettings.solidFonts = $0 }
                    ),
                    description:
                        "Draw text as solid pixels, with no soft edges. This looks sharper in some games."
                )
            }
        case .frameSkip, .vsync, .pathCache:
            EmptyView()
        }
    }
}

/// One section for the layout profile, which sets the controls and
/// where the game sits on screen.
struct LayoutSettingsSection: View {
    let model: GameSettingsModel
    @State private var showLayoutProfilePicker = false

    var body: some View {
        Section {
            Button {
                showLayoutProfilePicker = true
            } label: {
                HStack {
                    Text("Layout profile")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(currentPinLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(
                isPresented: $showLayoutProfilePicker,
                onDismiss: { model.reloadResolvedScreen() },
                content: {
                    LayoutProfilePickerSheet(container: model.container)
                }
            )
            .onAppear { model.reloadResolvedScreen() }
        } header: {
            Text("Layout")
        } footer: {
            if model.resolvedScreen?.portrait.placement != nil
                || model.resolvedScreen?.landscape.placement != nil
            {
                Text(
                    "Profiles live in Settings and work for any game. The profile also sets where the game sits on screen."
                )
            } else {
                Text("Profiles live in Settings and work for any game.")
            }
        }
    }

    private var currentPinLabel: String {
        switch LayoutProfilesManager.store.loadPin(forGameFolder: model.container.url).pin {
        case .followChain: return "Automatic"
        case .profile(let name): return name
        case .gameLayout: return "Game layout"
        case .defaultProfile: return "Default profile"
        }
    }
}

struct PerformanceSettingsSection: View {
    let model: GameSettingsModel

    var body: some View {
        Section {
            EngineFieldRow(model: model, field: .frameSkip) {
                SettingsToggle(
                    title: "Frame skip",
                    isOn: Binding(
                        get: { model.effectiveFrameSkip },
                        set: { model.engineSettings.frameSkip = $0 }
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
    }
}

struct PathCacheToggle: View {
    let model: GameSettingsModel

    var body: some View {
        EngineFieldRow(model: model, field: .pathCache) {
            SettingsToggle(
                title: "Path cache",
                isOn: Binding(
                    get: { model.effectivePathCache },
                    set: { model.engineSettings.pathCache = $0 }
                ),
                description:
                    "Keep a lowercase index of every game file so lookups are faster. Turn it off if the game can't find its images or sounds."
            )
        }
    }
}

struct TouchMouseToggle: View {
    let model: GameSettingsModel

    var body: some View {
        SettingsToggle(
            title: "Touch acts as mouse",
            isOn: Binding(
                get: { model.settings.touchMouseEnabled },
                set: { model.settings.touchMouse = $0 }
            ),
            description: "Send taps and drags on the game screen to the game as mouse input."
        )
    }
}

/// A row for a value of the engine overlay. It says so when the user
/// changed the value, and offers to set it back to the game's value.
struct EngineFieldRow<Content: View>: View {
    let model: GameSettingsModel
    let field: MkxpEngineField
    @ViewBuilder let content: Content

    var body: some View {
        let provenance = model.engineSettings.provenance(for: field)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            content
            // A row that still follows the game's own mkxp.json is the
            // normal state and gets no note.
            if provenance == .yours {
                Text("Changed by you")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if provenance == .yours {
                Button("Reset to game value") {
                    withAnimation { model.resetEngineField(field) }
                }
            }
        }
    }
}
