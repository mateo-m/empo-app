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
    /// Read to detect whether the engine is currently mid-session
    /// for this game (paused to library, then user opened Game
    /// Settings). When that's the case we surface a "restart
    /// required" hint after edits, since launch-time config fields
    /// won't take effect on resume.
    @Environment(\.pauseManager) private var pauseManager

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
        let defs = GameSettings.readGameDefaults(from: dir)

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
    /// Fast-forward is enabled when the user has set a multiplier.
    /// nil ↔ disabled. Toggling the switch ON seeds a sensible
    /// default (4x); the slider then ranges 2-9.
    private var fastForwardEnabled: Bool {
        settings.speedMultiplier != nil && (settings.speedMultiplier ?? 0) >= 2
    }
    /// Multiplier shown by the slider when fast-forward is enabled.
    /// Falls back to 4x while disabled (so flipping the toggle on
    /// lands on a useful default rather than 1x or nil).
    private var effectiveSpeedMultiplier: Int {
        let v = settings.speedMultiplier ?? 4
        return max(2, min(9, v))
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
    private var effectiveRenderScale: RenderScale {
        settings.renderScale ?? defaults.renderScale ?? GameConfigDefaults.engineRenderScale
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

    /// Hint to render at the top of the form when a session for
    /// this game is currently paused AND the user has changed at
    /// least one launch-time field since opening the sheet. The
    /// excerpt names the specific settings pending a relaunch so
    /// the user can see "Restart this game to apply: Smooth
    /// scaling and Render scale." instead of a generic notice.
    /// `nil` when no relaunch is needed - the parent view binds
    /// that to a conditional render so the pill animates in/out.
    private var restartHint: Hint? {
        guard pauseManager.pausedGame?.id == game.id else { return nil }
        let changed = settings.restartRequiredFieldsChanged(from: initialSettings)
        guard !changed.isEmpty else { return nil }
        let list = changed.formatted(.list(type: .and, width: .standard))
        return Hint(
            id: "gameSettings.restartRequired",
            excerpt: "Restart this game to apply: \(list).",
            description: nil,
            dismissal: .none,
            icon: "arrow.clockwise.circle.fill"
        )
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
                                defaults = GameSettings.readGameDefaults(from: gameDirectory)
                            }
                        }
                    } footer: {
                        Text("Remove all custom settings and use the game's original values.")
                    }
                }
            }
            // Pin the restart-required pill above the form via a
            // top safe-area inset. The inset gives the pill a
            // z-order above the scrolling rows for free; we don't
            // try to paint a wide backdrop in the inset's
            // surrounding area because that just produces a
            // visible white/gray panel in light mode (regardless
            // of whether we use material, color, or a blend of
            // both).
            //
            // The pill itself gets a `.regularMaterial` fill
            // clipped to the same rounded shape `HintBanner`
            // already uses internally - translucent so form rows
            // scrolling past show through with a blur, while
            // staying opaque enough that hint text doesn't visibly
            // collide with row labels underneath. The pill's own
            // brand-tinted layer (`.brand.opacity(0.1)` from
            // `HintBanner`) renders on top of the material, giving
            // the floating pill its brand cast.
            //
            // Slide+blur transition matches `.hintBanner` (same
            // one used by GameInfoView's customization hint). We
            // animate on the boolean (not the excerpt) so adding
            // or removing individual fields updates the text in
            // place without re-running the slide-in transition -
            // only true appear/disappear cycles trigger movement.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let hint = restartHint {
                    HintBanner(hint: hint)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: Radius.md)
                        )
                        .padding(.horizontal, Spacing._2xl)
                        .padding(.vertical, Spacing.md)
                        .transition(.hintBanner)
                }
            }
            .animation(.smooth(duration: 0.25), value: restartHint != nil)
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
                Picker("Render scale", selection: renderScaleBinding) {
                    ForEach(RenderScale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.navigationLink)

                Text(effectiveRenderScale.description
                    + " The game's aspect ratio and on-screen layout are unchanged - this only sharpens the rendering on high-DPI screens.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Text("Control how the game looks on screen.")
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
                SettingsToggle(
                    title: "Fast forward",
                    isOn: fastForwardEnabledBinding,
                    description: "Adds a Fast forward toggle to the in-game menu. While on, the game runs at the speed below."
                )

                if fastForwardEnabled {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(effectiveSpeedMultiplier)x")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: speedBinding,
                        in: 2...9,
                        step: 1
                    )
                }
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

    private var fastForwardEnabledBinding: Binding<Bool> {
        Binding(
            get: { fastForwardEnabled },
            set: { newValue in
                // Enabling: seed default 4x if no value yet (or if
                // a stale 1x lingers from the old single-slider UI).
                // Disabling: clear the multiplier so applyToConfig
                // and the toolbar sheet both treat the game as
                // fast-forward-free.
                if newValue {
                    if (settings.speedMultiplier ?? 0) < 2 {
                        settings.speedMultiplier = 4
                    }
                } else {
                    settings.speedMultiplier = nil
                }
            }
        )
    }

    /// Slider binding; only meaningful when fast-forward is enabled.
    /// Range 2-9 (1x is "off" and lives on the toggle now).
    private var speedBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveSpeedMultiplier) },
            set: { settings.speedMultiplier = Int($0) }
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

    private var renderScaleBinding: Binding<RenderScale> {
        Binding(
            get: { effectiveRenderScale },
            set: { settings.renderScale = $0 }
        )
    }


    private func save() {
        settings.save(to: stateDirectory)
        // Regenerate the merged mkxp.json so the engine
        // sees the new values on next launch. Without this, edits
        // here only land in game_settings.json (the host-side
        // record) and the engine keeps reading the stale config it
        // was launched with - making toggles like Smooth Scaling,
        // Vsync, and Resolution appear to do nothing.
        settings.applyToConfig(stateDirectory: stateDirectory, gameDirectory: gameDirectory)
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
