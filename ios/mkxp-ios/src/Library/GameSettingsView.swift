import SwiftUI

struct GameSettingsView: View {
    let game: GameEntry
    @Environment(\.dismiss) private var dismiss

    @State private var settings: GameSettings
    @State private var cheats: Bool
    @State private var defaults: GameConfigDefaults
    @State private var needsRestart = false

    private let gameDirectory: URL
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
        self.initialSettings = s
    }

    // MARK: - Effective Values

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
    private var effectiveVsync: Bool {
        settings.vsync ?? defaults.vsync ?? GameConfigDefaults.engineVsync
    }
    private var effectivePathCache: Bool {
        settings.pathCache ?? defaults.pathCache ?? GameConfigDefaults.enginePathCache
    }
    private var effectiveSolidFonts: Bool {
        settings.solidFonts ?? defaults.solidFonts ?? GameConfigDefaults.engineSolidFonts
    }
    private var effectivePostloadScripts: Bool {
        settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
    }
    private var effectiveVerticalAlignment: VerticalAlignment {
        settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
    }
    private var effectiveResolution: ResolutionPreset? {
        settings.resolution ?? defaults.resolution
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Gameplay ─────────────────────────────────
                gameplaySection

                // ── Display ──────────────────────────────────
                displaySection

                // ── Portrait Layout ──────────────────────────
                verticalAlignmentSection

                // ── Performance ──────────────────────────────
                performanceSection

                // ── Engine ───────────────────────────────────
                engineSection

                // ── Reset ────────────────────────────────────
                if settings.hasCustomizations {
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
            .onChange(of: settings.vsync) { save() }
            .onChange(of: settings.pathCache) { save() }
            .onChange(of: settings.solidFonts) { save() }
            .onChange(of: settings.postloadScripts) { save() }
            .onChange(of: settings.verticalAlignment) { save() }
            .onChange(of: settings.resolution) { save() }
            .onChange(of: cheats) { saveCheats() }
        }
        .tint(.brand)
    }

    // MARK: - Sections

    private var displaySection: some View {
        Section {
            SettingsToggle(
                title: "Smooth scaling",
                isOn: smoothScalingBinding,
                description: "Use bilinear filtering when upscaling. Disable for a pixel-perfect look."
            )

            SettingsToggle(
                title: "Fixed aspect ratio",
                isOn: fixedAspectRatioBinding,
                description: "Preserve the game's proportions instead of stretching to fill the screen."
            )

            SettingsToggle(
                title: "VSync",
                isOn: vsyncBinding,
                description: "Synchronize rendering with the display refresh rate to reduce tearing."
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker("Resolution", selection: resolutionBinding) {
                    Text("Default")
                        .tag(nil as ResolutionPreset?)

                    ForEach(ResolutionPreset.presets) { preset in
                        HStack {
                            Text(preset.label)
                            Spacer()
                            Text(preset.aspectRatio)
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset as ResolutionPreset?)
                    }
                }
                .pickerStyle(.navigationLink)

                if let res = effectiveResolution {
                    Text("Currently \(res.label) (\(res.aspectRatio)). Some games may override this in their scripts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Override the game's internal resolution. Some games may override this in their scripts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.xxs)

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("Font scale")
                    Spacer()
                    Text(String(format: "%.1fx", effectiveFontScale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fontScaleBinding,
                    in: 0.5...2.0,
                    step: 0.1
                )
                Text("Scale all in-game text. 1.0x is the default size.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)

            SettingsToggle(
                title: "Solid fonts",
                isOn: solidFontsBinding,
                description: "Disable alpha blending for text, which can look sharper in some games."
            )
        } header: {
            Text("Display")
        } footer: {
            Text("Control how the game looks on screen. Changes take effect on next launch.")
        }
    }

    private var verticalAlignmentSection: some View {
        Section {
            Picker("Position", selection: verticalAlignmentBinding) {
                ForEach(VerticalAlignment.allCases, id: \.self) { alignment in
                    HStack(spacing: 10) {
                        VerticalAlignmentIllustration(alignment: alignment)
                            .frame(width: 24, height: 40)
                        Text(alignment.label)
                    }
                    .tag(alignment)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Portrait layout")
        } footer: {
            Text("Where the game sits on screen when playing in portrait. Controls appear below.")
        }
    }

    private var performanceSection: some View {
        Section {
            SettingsToggle(
                title: "Frame skip",
                isOn: frameSkipBinding,
                description: "Skip rendering frames when the game falls behind. Can improve performance at the cost of smoothness."
            )
        } header: {
            Text("Performance")
        } footer: {
            Text("Tune how the engine handles demanding scenes.")
        }
    }


    private var engineSection: some View {
        Section {
            SettingsToggle(
                title: "Postload scripts",
                isOn: postloadScriptsBinding,
                description: "Run scripts that apply common fixes for Pokemon Essentials games."
            )

            SettingsToggle(
                title: "Path cache",
                isOn: pathCacheBinding,
                description: "Index files with lowercase paths for faster lookup. Disable if the game has missing asset issues."
            )
        } header: {
            Text("Engine")
        } footer: {
            Text("Low-level engine options that affect compatibility and loading.")
        }
    }

    private var gameplaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("Fast forward")
                    Spacer()
                    Text("\(effectiveSpeedMultiplier)x")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: speedBinding,
                    in: 1...9,
                    step: 1
                )
                Text("Run the game at a faster speed. 1x is normal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)

            SettingsToggle(
                title: "Cheats",
                isOn: $cheats,
                description: "Enable cheat mode. Only works if the game supports it."
            )
        } header: {
            Text("Gameplay")
        } footer: {
            Text("Options that change how you play the game.")
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

    private var vsyncBinding: Binding<Bool> {
        Binding(
            get: { effectiveVsync },
            set: { settings.vsync = $0 }
        )
    }

    private var pathCacheBinding: Binding<Bool> {
        Binding(
            get: { effectivePathCache },
            set: { settings.pathCache = $0 }
        )
    }

    private var solidFontsBinding: Binding<Bool> {
        Binding(
            get: { effectiveSolidFonts },
            set: { settings.solidFonts = $0 }
        )
    }

    private var postloadScriptsBinding: Binding<Bool> {
        Binding(
            get: { effectivePostloadScripts },
            set: { settings.postloadScripts = $0 }
        )
    }

    private var verticalAlignmentBinding: Binding<VerticalAlignment> {
        Binding(
            get: { effectiveVerticalAlignment },
            set: { settings.verticalAlignment = $0 }
        )
    }

    private var resolutionBinding: Binding<ResolutionPreset?> {
        Binding(
            get: { settings.resolution },
            set: { settings.resolution = $0 }
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

// MARK: - Vertical Alignment Illustration

/// A tiny illustration showing where the game viewport sits on a phone silhouette.
private struct VerticalAlignmentIllustration: View {
    let alignment: VerticalAlignment

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let phoneInset: CGFloat = 2
            let innerW = w - phoneInset * 2
            let innerH = h - phoneInset * 2
            let gameH: CGFloat = innerH * 0.35

            let gameY: CGFloat = switch alignment {
            case .top:
                phoneInset + 2
            case .topCenter:
                phoneInset + (innerH - gameH) * 0.25
            case .center:
                phoneInset + (innerH - gameH) / 2
            }

            ZStack {
                // Phone outline
                RoundedRectangle(cornerRadius: Radius.xs)
                    .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: w, height: h)

                // Game viewport
                RoundedRectangle(cornerRadius: Spacing.xxs)
                    .fill(.tint.opacity(0.6))
                    .frame(width: innerW - 4, height: gameH)
                    .position(x: w / 2, y: gameY + gameH / 2)
            }
        }
    }
}
