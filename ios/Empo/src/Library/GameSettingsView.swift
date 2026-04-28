import SwiftUI

/// Per-game Ruby interpreter version selection exposed in the
/// Game Settings sheet. Maps to `GameSettings.rubyVersionOverride`:
///   auto -> nil (use auto-detection from `metadata.rubyVersion`)
///   v18 / v19 / v30 / v31 -> force that interpreter version
///
/// Detection lives in `RubyVersionDetection` and runs at import
/// time; this picker is the manual escape hatch when it misses.
enum RubyVersionPick: String, CaseIterable, Hashable {
    case auto
    case v18
    case v19
    case v30
    case v31

    var rawValue_: Int? {
        switch self {
        case .auto: return nil
        case .v18: return 18
        case .v19: return 19
        case .v30: return 30
        case .v31: return 31
        }
    }

    static func from(_ value: Int?) -> RubyVersionPick {
        switch value {
        case 18: return .v18
        case 19: return .v19
        case 30: return .v30
        case 31: return .v31
        default: return .auto
        }
    }

    var displayLabel: String {
        switch self {
        case .auto: return "Auto-detect"
        case .v18: return "Ruby 1.8"
        case .v19: return "Ruby 1.9"
        case .v30: return "Ruby 3.0"
        case .v31: return "Ruby 3.1"
        }
    }
}

struct GameSettingsView: View {
    let game: GameEntry
    @Environment(\.dismiss) private var dismiss

    @State private var settings: GameSettings
    @State private var defaults: GameConfigDefaults
    /// Auto-detected Ruby version raw value (18/19/30/31), read
    /// from `metadata.rubyVersion`. Populated when the sheet
    /// opens, used to dress the "Auto-detect" picker row with the
    /// version the detector picked - so users can see what
    /// Auto-detect would route to without flipping the override.
    @State private var autoDetectedVersion: Int?

    private let gameDirectory: URL
    private let stateDirectory: URL
    private let initialSettings: GameSettings
    /// Computed once at init: true if the game's `Game.ini` Title
    /// contains a Pokemon-family keyword. Used as the default for
    /// the In-game keyboard toggle when the user hasn't explicitly
    /// set `settings.useInGameKeyboard`. Cached so the toggle UI
    /// doesn't re-read the file on every render.
    private let isPokemonEssentialsDefault: Bool

    init(game: GameEntry) {
        self.game = game
        // Per-game managed config (mkxp.json, game_settings.json)
        // lives at `<container>/EmpoState/`, alongside the imported
        // `Game/` subdir. Both paths come from the same
        // `GameContainer`. Settings UI assumes a non-synthetic
        // entry (one with a real container on disk).
        let container = game.container!
        let dir = container.gameURL
        self.gameDirectory = dir
        let stateDir = container.empoStateURL
        self.stateDirectory = stateDir

        let s = GameSettings.load(from: stateDir)
        let defs = GameSettings.readGameDefaults(from: stateDir)

        _settings = State(initialValue: s)
        _defaults = State(initialValue: defs)
        self.initialSettings = s
        self.isPokemonEssentialsDefault = GameSettings.detectPokemonEssentials(
            in: dir, stateDirectory: stateDir
        )
    }


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

    /// Human-readable label for the "Auto-detect" picker row that
    /// also reveals which version the detector resolved to. Reads
    /// `autoDetectedVersion` (loaded from metadata when the sheet
    /// opens):
    ///   - not yet loaded -> "Auto-detect"
    ///   - detected -> "Auto-detect (Ruby X.Y)"
    private var autoDetectLabel: String {
        guard let v = autoDetectedVersion else { return "Auto-detect" }
        let pretty: String
        switch v {
        case 18: pretty = "Ruby 1.8"
        case 19: pretty = "Ruby 1.9"
        case 30: pretty = "Ruby 3.0"
        case 31: pretty = "Ruby 3.1"
        default: return "Auto-detect"
        }
        return "Auto-detect (\(pretty))"
    }

    var body: some View {
        NavigationStack {
            Form {
                gameplaySection
                displaySection
                verticalAlignmentSection
                performanceSection
                engineSection

                if settings.hasCustomizations {
                    Section {
                        Button("Reset to Defaults", role: .destructive) {
                            withAnimation {
                                settings = GameSettings()
                                defaults = GameSettings.readGameDefaults(from: stateDirectory)
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("Settings")
                            .font(.headline)
                    }
                    .sheetTitle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings) { save() }
            .task {
                // Read the import-time auto-detected Ruby version
                // from metadata so the "Auto-detect" picker row
                // shows what would be routed to. Also kicks off
                // the legacy modern-Ruby script scanner for
                // backward-compat consumers (postload scripts,
                // older builds reading useModernRuby).
                if let container = game.container {
                    let metadata = GameMetadata.load(from: container)
                    autoDetectedVersion = metadata.rubyVersion
                }
            }
        }
        .tint(.brand)
    }


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
                description: "Run Empo's compatibility scripts after the game's own scripts have loaded. Includes generic RGSS shims (RGSS plugin stubs, cheat menu, nil-safe stubs) and Pokemon Essentials specific fixes (graphics, input, online stubs, session reset, tilemap, window skin)."
            )

            SettingsToggle(
                title: "Path cache",
                isOn: pathCacheBinding,
                description: "Index files with lowercase paths for faster lookup. Disable if the game has missing asset issues."
            )

            SettingsToggle(
                title: "In-game keyboard",
                isOn: useInGameKeyboardBinding,
                description: "Use the game's built-in keyboard scene for name entry instead of the iOS soft keyboard. Enable for Pokemon Essentials games whose keyboard layout has custom keys."
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker("Ruby version", selection: rubyVersionBinding) {
                    Text(autoDetectLabel).tag(RubyVersionPick.auto)
                    Text(RubyVersionPick.v18.displayLabel).tag(RubyVersionPick.v18)
                    Text(RubyVersionPick.v19.displayLabel).tag(RubyVersionPick.v19)
                    Text(RubyVersionPick.v30.displayLabel).tag(RubyVersionPick.v30)
                    Text(RubyVersionPick.v31.displayLabel).tag(RubyVersionPick.v31)
                }
                .pickerStyle(.navigationLink)

                Text("Auto-detect inspects the game's scripts and picks the matching Ruby interpreter. Override only if the game fails to launch with a script error or behaves incorrectly.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)
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
        } header: {
            Text("Gameplay")
        } footer: {
            // Cheats live in App Settings (Experimental section) -
            // the per-game toggle was orthogonal stored-but-unused
            // state, see commit message and TODO.md "P0 #3".
            Text("Options that change how you play the game.")
        }
    }


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

    private var useInGameKeyboardBinding: Binding<Bool> {
        Binding(
            get: { settings.useInGameKeyboard ?? isPokemonEssentialsDefault },
            set: { settings.useInGameKeyboard = $0 }
        )
    }

    /// Picker backing for `GameSettings.rubyVersionOverride`:
    /// nil  -> .auto (use detection from metadata.rubyVersion),
    /// 18/19/30/31 -> force that Ruby interpreter version.
    private var rubyVersionBinding: Binding<RubyVersionPick> {
        Binding(
            get: { RubyVersionPick.from(settings.rubyVersionOverride) },
            set: { pick in
                settings.rubyVersionOverride = pick.rawValue_
            }
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


    private func save() {
        settings.save(to: stateDirectory)
    }
}


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
