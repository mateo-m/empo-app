import SwiftUI

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var featureToEnable: ExperimentalFeature?
    @State private var pendingRenderer: RendererOption?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.brand)
                        Text(AppInfo.name)
                            .font(.title3)
                            .fontWeight(.bold)
                        Text("\(GitInfo.commit)\(GitInfo.dirty ? " (dirty)" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .listRowBackground(Color.clear)
                }

                Section {
                    SettingsPicker(
                        title: "Theme",
                        selection: $settings.theme,
                        description: "Switch between dark, light, or system appearance."
                    ) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }

                    SettingsPicker(
                        title: "View mode",
                        selection: $settings.libraryDisplayMode,
                        description: "Show games as a grid of cards or a compact list."
                    ) {
                        ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    SettingsPicker(
                        title: "Title position",
                        selection: $settings.titlePosition,
                        description: "Where game titles show up on your library cards."
                    ) {
                        ForEach(TitlePosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }

                    SettingsToggle(
                        title: "Interface haptics",
                        isOn: $settings.interfaceHaptics,
                        description: "Gentle taps when you press buttons, toggle switches, and navigate around."
                    )

                    SettingsToggle(
                        title: "Controller haptics",
                        isOn: $settings.controllerHaptics,
                        description: "Vibration feedback on the on-screen game controls while you play."
                    )

                    SettingsToggle(
                        title: "Continue playing",
                        isOn: $settings.showContinuePlaying,
                        description: "Show a card at the top of your library to quickly jump back into your last game."
                    )
                } header: {
                    Text("Look & Feel")
                } footer: {
                    Text("Customize the appearance and layout of your library.")
                }

                Section {
                    SettingsPicker(
                        title: "Renderer",
                        selection: Binding(
                            get: { settings.renderer },
                            set: { newValue in
                                if newValue == .angle && settings.renderer != .angle {
                                    pendingRenderer = newValue
                                } else {
                                    settings.renderer = newValue
                                }
                            }
                        ),
                        description: "OpenGL ES is the stable default. ANGLE is experimental and translates OpenGL calls to Metal.",
                        // Show the BETA badge next to the picker's label
                        // only when the user has selected a beta-flagged
                        // renderer, rather than baking "(Beta)" into the
                        // menu items. Keeps the picker entries terse.
                        isExperimental: settings.renderer.isBeta
                    ) {
                        ForEach(RendererOption.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    SettingsToggle(
                        title: "Pause game",
                        isOn: experimentalBinding(for: .gamePause),
                        description: ExperimentalFeature.gamePause.description,
                        isExperimental: true
                    )

                    SettingsToggle(
                        title: "Quit game",
                        isOn: experimentalBinding(for: .gameQuit),
                        description: ExperimentalFeature.gameQuit.description,
                        isExperimental: true
                    )

                    SettingsToggle(
                        title: "Game overlay",
                        isOn: $settings.debugMode,
                        description: "Adds a button to the in-game toolbar that toggles a draggable overlay showing the title, Ruby version, renderer, and FPS."
                    )

                    SettingsToggle(
                        title: "Show viewport bounds",
                        isOn: $settings.showViewportBounds,
                        description: "Fills the framebuffer area outside the game viewport with a color of your choosing."
                    )

                    if settings.showViewportBounds {
                        NavigationLink {
                            ViewportBoundsColorPicker(color: $settings.viewportBoundsColor)
                        } label: {
                            HStack {
                                Text("Bounds color")
                                Spacer()
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .fill(settings.viewportBoundsColor)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    }

                    SettingsToggle(
                        title: "Clean up broken imports",
                        isOn: $settings.cleanupInvalidGames,
                        description: "Removes games that didn't import properly on the next app launch."
                    )

                    SettingsToggle(
                        title: "Debug logs",
                        isOn: $settings.debugLogs,
                        description: "Saves engine logs for each session. Find them in Files → \(AppInfo.name) → Logs."
                    )

                    if settings.debugLogs {
                        VStack(alignment: .leading, spacing: 4) {
                            Stepper("Keep last \(settings.maxLogFiles) logs", value: $settings.maxLogFiles, in: 5...100, step: 5)
                            Text("Older logs get cleaned up automatically on launch.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("These options are intended for debugging and troubleshooting.")
                }

            }
            // Experimental-feature opt-in sheet. Both toggle-driven
            // features AND the ANGLE renderer switch funnel through the
            // same presentation so the two confirmation flows feel
            // identical. Sheets sit better than alerts for this kind
            // of "take a moment to read" moment, and they don't
            // anchor to any specific row the way a popover would.
            .sheet(
                isPresented: Binding(
                    get: { featureToEnable != nil },
                    set: { if !$0 { featureToEnable = nil } }
                )
            ) {
                if let feature = featureToEnable {
                    ExperimentalConfirmSheet(
                        title: feature.label,
                        message: feature.description,
                        onCancel: { featureToEnable = nil },
                        onConfirm: {
                            settings.setEnabled(feature, true)
                            featureToEnable = nil
                        }
                    )
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { pendingRenderer != nil },
                    set: { if !$0 { pendingRenderer = nil } }
                )
            ) {
                ExperimentalConfirmSheet(
                    title: "ANGLE",
                    message: "ANGLE translates OpenGL calls to Metal and may cause rendering issues. The change will apply on the next game launch.",
                    onCancel: { pendingRenderer = nil },
                    onConfirm: {
                        if let renderer = pendingRenderer {
                            settings.renderer = renderer
                        }
                        pendingRenderer = nil
                    }
                )
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.brand)
    }

    private func experimentalBinding(for feature: ExperimentalFeature) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(feature) },
            set: { newValue in
                if newValue {
                    featureToEnable = feature
                } else {
                    settings.setEnabled(feature, false)
                }
            }
        )
    }
}


private struct ViewportBoundsColorPicker: View {
    @Binding var color: Color

    var body: some View {
        Form {
            Section {
                ColorPicker("Color", selection: $color, supportsOpacity: true)
            }

            Section {
                HStack(spacing: 20) {
                    Spacer()
                    DevicePreview(color: color, isLandscape: false)
                    DevicePreview(color: color, isLandscape: true)
                    Spacer()
                }
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("Bounds color")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Miniature device mockup showing the game viewport and bounds color.
private struct DevicePreview: View {
    let color: Color
    let isLandscape: Bool

    // Device proportions (roughly iPhone-like)
    private let portraitW: CGFloat = 70
    private let portraitH: CGFloat = 150
    private let cornerRadius: CGFloat = Radius.md
    private let bezelWidth: CGFloat = 2
    private let notchHeight: CGFloat = 8

    private var deviceW: CGFloat { isLandscape ? portraitH : portraitW }
    private var deviceH: CGFloat { isLandscape ? portraitW : portraitH }

    var body: some View {
        ZStack {
            // Device bezel
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.secondary.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.secondary.opacity(0.4), lineWidth: 1)
                )

            // Screen area
            let screenInset = bezelWidth + 2
            let screenW = deviceW - screenInset * 2
            let screenH = deviceH - screenInset * 2

            RoundedRectangle(cornerRadius: cornerRadius - 3)
                .fill(color)
                .padding(screenInset)

            // Game viewport
            let gameRect = gameViewportRect(screenW: screenW, screenH: screenH)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black)
                .frame(width: gameRect.width, height: gameRect.height)
                .offset(x: gameRect.offsetX, y: gameRect.offsetY)

            // Notch indicator
            notchView
        }
        .frame(width: deviceW, height: deviceH)
    }

    private var notchView: some View {
        Group {
            if isLandscape {
                // Notch on the left
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 4
                )
                .fill(.secondary.opacity(0.3))
                .frame(width: notchHeight, height: 20)
                .offset(x: -(deviceW / 2 - notchHeight / 2))
            } else {
                // Notch on top
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 0
                )
                .fill(.secondary.opacity(0.3))
                .frame(width: 28, height: notchHeight)
                .offset(y: -(deviceH / 2 - notchHeight / 2))
            }
        }
    }

    private struct GameRect {
        let width: CGFloat
        let height: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    private func gameViewportRect(screenW: CGFloat, screenH: CGFloat) -> GameRect {
        // Simulate a 4:3 game aspect ratio
        let gameAspect: CGFloat = 4.0 / 3.0
        let safeTopInset: CGFloat = notchHeight + 2

        if isLandscape {
            // Landscape: game centered, safe insets on left
            let safeLeftInset: CGFloat = notchHeight + 2
            let availW = screenW - safeLeftInset
            let availH = screenH
            var gameW = availW
            var gameH = gameW / gameAspect
            if gameH > availH {
                gameH = availH
                gameW = gameH * gameAspect
            }
            let offsetX = (safeLeftInset - 0) / 2
            return GameRect(width: gameW, height: gameH, offsetX: offsetX, offsetY: 0)
        } else {
            // Portrait: game top-center aligned within safe area
            let availW = screenW
            let availH = screenH - safeTopInset
            var gameW = availW
            var gameH = gameW / gameAspect
            if gameH > availH * 0.6 {
                gameH = availH * 0.6
                gameW = gameH * gameAspect
            }
            // Top-center: between top and center
            let topY = -(screenH / 2 - safeTopInset - gameH / 2 - 2)
            let centerY: CGFloat = 0
            let offsetY = (topY + centerY) / 2
            return GameRect(width: gameW, height: gameH, offsetX: 0, offsetY: offsetY)
        }
    }
}
