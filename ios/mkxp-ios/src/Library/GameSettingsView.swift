import SwiftUI

struct GameSettingsView: View {
    let game: GameEntry
    @Environment(\.dismiss) private var dismiss

    @State private var settings: GameSettings
    @State private var cheats: Bool
    @State private var defaults: GameConfigDefaults
    @State private var needsRestart = false

    private let gameDirectory: URL
    private let isGameRunning: Bool
    private let initialSettings: GameSettings

    init(game: GameEntry) {
        self.game = game
        let dir = URL(fileURLWithPath: game.path)
        self.gameDirectory = dir

        let s = GameSettings.load(from: dir)
        let defs = GameSettings.readGameDefaults(from: dir)
        let cheatsVal = GameSettings.loadCheats(from: dir)

        _settings = State(initialValue: s)
        _cheats = State(initialValue: cheatsVal)
        _defaults = State(initialValue: defs)
    }

    // Effective values: override ?? game default ?? engine default
    private var effectiveSmoothScaling: Bool {
        settings.smoothScaling ?? defaults.smoothScaling ?? GameConfigDefaults.engineSmoothScaling
    }
    private var effectiveFixedAspectRatio: Bool {
        settings.fixedAspectRatio ?? defaults.fixedAspectRatio ?? GameConfigDefaults.engineFixedAspectRatio
    }
    private var effectiveFrameSkip: Bool {
        settings.frameSkip ?? defaults.frameSkip ?? GameConfigDefaults.engineFrameSkip
    }
    private var effectiveSpeedMultiplier: Int {
        settings.speedMultiplier ?? 1
    }
    private var effectiveFontScale: Double {
        settings.fontScale ?? defaults.fontScale ?? GameConfigDefaults.engineFontScale
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Smooth Scaling", isOn: smoothScalingBinding)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Use bilinear filtering when upscaling. Disable for a pixel-perfect look.")
                }

                Section {
                    Toggle("Fixed Aspect Ratio", isOn: fixedAspectRatioBinding)
                } footer: {
                    Text("Preserve the game's aspect ratio instead of stretching to fill the screen.")
                }

                Section {
                    Toggle("Frame Skip", isOn: frameSkipBinding)
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Skip rendering frames when the game falls behind. Can improve performance at the cost of visual smoothness.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(effectiveSpeedMultiplier)×")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: speedBinding,
                            in: 1...9,
                            step: 1
                        )
                    }
                    .padding(.vertical, 2)
                } footer: {
                    Text("Run the game faster. Requires restarting the game to take effect.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Font Scale")
                            Spacer()
                            Text(String(format: "%.1f×", effectiveFontScale))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: fontScaleBinding,
                            in: 0.5...2.0,
                            step: 0.1
                        )
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Text")
                } footer: {
                    Text("Scale all in-game text. 1.0× is the default size.")
                }

                Section {
                    Toggle("Cheats", isOn: $cheats)
                } header: {
                    Text("Gameplay")
                } footer: {
                    Text("Enable cheat mode. Only works if the game supports it.")
                }

                if settings.smoothScaling != nil || settings.fixedAspectRatio != nil ||
                   settings.frameSkip != nil || settings.speedMultiplier != nil || settings.fontScale != nil {
                    Section {
                        Button("Reset to Defaults", role: .destructive) {
                            withAnimation {
                                settings = GameSettings()
                                defaults = GameSettings.readGameDefaults(from: gameDirectory)
                            }
                        }
                    } footer: {
                        Text("Remove all custom settings and use the game's original values.")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(game.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Settings")
                            .font(.headline)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings.smoothScaling) { save() }
            .onChange(of: settings.fixedAspectRatio) { save() }
            .onChange(of: settings.frameSkip) { save() }
            .onChange(of: settings.speedMultiplier) { save() }
            .onChange(of: settings.fontScale) { save() }
            .onChange(of: cheats) { saveCheats() }
        }
    }

    // MARK: - Bindings

    private var smoothScalingBinding: Binding<Bool> {
        Binding(
            get: { effectiveSmoothScaling },
            set: { settings.smoothScaling = $0 }
        )
    }

    private var fixedAspectRatioBinding: Binding<Bool> {
        Binding(
            get: { effectiveFixedAspectRatio },
            set: { settings.fixedAspectRatio = $0 }
        )
    }

    private var frameSkipBinding: Binding<Bool> {
        Binding(
            get: { effectiveFrameSkip },
            set: { settings.frameSkip = $0 }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveSpeedMultiplier) },
            set: { settings.speedMultiplier = Int($0) == 1 ? nil : Int($0) }
        )
    }

    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { effectiveFontScale },
            set: { settings.fontScale = $0 }
        )
    }

    // MARK: - Persistence

    private func save() {
        settings.save(to: gameDirectory)
    }

    private func saveCheats() {
        GameSettings.saveCheats(cheats, to: gameDirectory)
    }
}
