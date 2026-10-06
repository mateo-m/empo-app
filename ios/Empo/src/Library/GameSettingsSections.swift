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

enum DisplayField {
    case smoothScaling
    case fixedAspectRatio
}

/// The shared display rows of `fields`, in that order, then the
/// core's own rows.
struct DisplaySettingsSection<Extra: View>: View {
    let model: GameSettingsModel
    let fields: [DisplayField]
    @ViewBuilder let extra: Extra

    var body: some View {
        Section {
            if model.displayDefaults.unreadable {
                Text(
                    "Empo can't read this game's own settings, so the values below start from Empo's defaults."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(fields, id: \.self) { field in
                row(field)
            }
            extra
        } header: {
            Text("Display")
        } footer: {
            Text("How the game looks on screen.")
        }
    }

    @ViewBuilder
    private func row(_ field: DisplayField) -> some View {
        switch field {
        case .smoothScaling:
            SettingRow(isChanged: model.settings.smoothScaling != nil) {
                model.settings.smoothScaling = nil
            } content: {
                SettingsToggle(
                    title: "Smooth scaling",
                    isOn: Binding(
                        get: { model.effectiveSmoothScaling },
                        set: { model.settings.smoothScaling = $0 }
                    ),
                    description:
                        "Smooth the picture when the game scales up. Turn it off to keep the pixels crisp."
                )
            }
        case .fixedAspectRatio:
            SettingRow(isChanged: model.settings.fixedAspectRatio != nil) {
                model.settings.fixedAspectRatio = nil
            } content: {
                SettingsToggle(
                    title: "Fixed aspect ratio",
                    isOn: Binding(
                        get: { model.effectiveFixedAspectRatio },
                        set: { model.settings.fixedAspectRatio = $0 }
                    ),
                    description:
                        "Preserve the game's proportions instead of stretching to fill the screen."
                )
            }
        }
    }
}

extension DisplaySettingsSection where Extra == EmptyView {
    init(model: GameSettingsModel, fields: [DisplayField]) {
        self.init(model: model, fields: fields) { EmptyView() }
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

/// A row for a value the user can set. It says so when the user
/// changed the value, and offers to set it back to the game's value.
struct SettingRow<Content: View>: View {
    let isChanged: Bool
    let reset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            content
            // A row that still follows the game's own value is the
            // normal state and gets no note.
            if isChanged {
                Text("Changed by you")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if isChanged {
                Button("Reset to game value") {
                    withAnimation { reset() }
                }
            }
        }
    }
}
