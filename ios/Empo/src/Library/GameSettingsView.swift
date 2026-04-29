import SwiftUI

/// Three-way Ruby parser compatibility selection exposed in the
/// Game Settings sheet. Maps to `GameSettings.useModernRuby`:
///   auto   -> nil  (detector scans .rb files at launch)
///   modern -> true (force syntaxTransform = 0, Ruby 3 strict)
///   compat -> false (force syntaxTransform = 2, Ruby 1.8 compat)
enum RubyCompatMode: String, CaseIterable, Hashable {
    case auto
    case modern
    case compat
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
    /// Result of the Ruby-syntax scanner used by `useModernRuby = nil`
    /// ("auto"). nil while the scan is still running, then true if
    /// the game ships Ruby 3 source, false otherwise. Surfaced in
    /// the picker label so users see what "Auto-detect" would pick
    /// without having to flip the setting and watch the game start.
    @State private var autoDetectedModern: Bool?

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
    /// also reveals which mode the scanner resolved to. Reads
    /// `autoDetectedModern` (populated by the .task scan):
    ///   - while scanning -> "Auto-detect"
    ///   - scan done, modern hit -> "Auto-detect (Modern)"
    ///   - scan done, no hit -> "Auto-detect (Legacy)"
    private var autoDetectLabel: String {
        switch autoDetectedModern {
        case nil:           "Auto-detect"
        case .some(true):   "Auto-detect (Modern)"
        case .some(false):  "Auto-detect (Legacy)"
        }
    }

    /// True when this game's session is currently active (paused to
    /// the library) AND the user has changed at least one
    /// restart-required field since opening the sheet. Drives the
    /// banner at the top of the form so the user knows their edits
    /// won't apply until the next full launch.
    private var showRestartHint: Bool {
        pauseManager.pausedGame?.id == game.id
            && settings.differsInRestartRequiredFields(from: initialSettings)
    }

    var body: some View {
        NavigationStack {
            Form {
                if showRestartHint {
                    Section {
                        Label {
                            Text("Restart this game for changes to take effect.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        .listRowBackground(Color.orange.opacity(0.12))
                    }
                }

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
                // Run the Ruby-syntax scanner off the main thread.
                // detectModernRubyScripts walks `Scripts/` and
                // `Data/` looking for keyword-arg shorthand and can
                // visit a few hundred .rb files on big fangames -
                // doing it on the main actor would stutter the
                // sheet open animation. We don't need cancellation
                // because the scanner has its own bounded work
                // (`scanCap = 2000` files, returns on first match).
                let dir = gameDirectory
                let result = await Task.detached(priority: .userInitiated) {
                    GameSettings.detectModernRubyScripts(in: dir)
                }.value
                autoDetectedModern = result
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
                Picker("Ruby compatibility", selection: rubyCompatBinding) {
                    Text(autoDetectLabel).tag(RubyCompatMode.auto)
                    Text("Modern (Ruby 3)").tag(RubyCompatMode.modern)
                    Text("Legacy (Ruby 1.8)").tag(RubyCompatMode.compat)
                }
                .pickerStyle(.navigationLink)

                Text("Auto-detect scans the game's scripts and picks Modern if it finds Ruby-3-only syntax, otherwise Legacy. Override if a game fails to launch with a script error or behaves incorrectly.")
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

    /// Tri-state picker backing for `GameSettings.useModernRuby`:
    /// nil -> auto (run the Ruby-3-syntax detector on launch),
    /// true -> force Modern (syntaxTransform = 0),
    /// false -> force Legacy (syntaxTransform = 2).
    private var rubyCompatBinding: Binding<RubyCompatMode> {
        Binding(
            get: {
                switch settings.useModernRuby {
                case nil: return .auto
                case .some(true): return .modern
                case .some(false): return .compat
                }
            },
            set: { mode in
                switch mode {
                case .auto: settings.useModernRuby = nil
                case .modern: settings.useModernRuby = true
                case .compat: settings.useModernRuby = false
                }
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
        // Regenerate the merged mkxp.json so the engine actually
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
