import GameProbe
import SwiftUI

/// Per-game Ruby interpreter version selection exposed in the
/// Game Settings sheet. Maps to `GameSettings.rubyVersionOverride`:
///   auto -> nil (use auto-detection from `metadata.rubyVersion`)
///   v18 / v19 / v31 -> force that interpreter version
///
/// Detection lives in `RubyVersionDetection` and runs at import
/// time. This picker is the manual override when detection misses.
enum RubyVersionPick: String, CaseIterable, Hashable {
    case auto
    case v18
    case v19
    case v31

    var rubyVersionInt: Int? {
        switch self {
        case .auto: return nil
        case .v18: return 18
        case .v19: return 19
        case .v31: return 31
        }
    }

    /// Decoder for `GameSettings.rubyVersionOverride` and
    /// auto-detected `metadata.rubyVersion`. Old data may have 30
    /// from when the project shipped a native Ruby 3.0 binding.
    /// Fold it onto v31 since the dispatcher routes 30 to the 3.1
    /// runtime + Legacy syntax-transform anyway.
    static func from(_ value: Int?) -> RubyVersionPick {
        switch value {
        case 18: return .v18
        case 19: return .v19
        case 30, 31: return .v31
        default: return .auto
        }
    }

    var displayLabel: String {
        switch self {
        case .auto: return "Auto-detect"
        case .v18: return "Ruby 1.8"
        case .v19: return "Ruby 1.9"
        case .v31: return "Ruby 3.1"
        }
    }
}

/// Compatibility-mode pick for the Game Settings sheet. Backs
/// `GameSettings.useModernRuby`. Resolved to a
/// `MKXPSyntaxTransformMode` at engine boot via
/// `GameSettings.resolveSyntaxTransformMode`. Effective only on
/// the patched Ruby 3.1 build. Selecting "Legacy" with the 1.x
/// or 3.0 native interpreter is a no-op (the warning footer in
/// the picker calls this out).
enum CompatibilityPick: String, CaseIterable, Hashable {
    case auto
    case modern
    case legacy

    var useModernRubyValue: Bool? {
        switch self {
        case .auto: return nil
        case .modern: return true
        case .legacy: return false
        }
    }

    static func from(_ value: Bool?) -> CompatibilityPick {
        switch value {
        case true?: return .modern
        case false?: return .legacy
        case nil: return .auto
        }
    }

    var displayLabel: String {
        switch self {
        case .auto: return "Auto-detect"
        case .modern: return "Modern (Ruby 3 strict)"
        case .legacy: return "Legacy (rewrite Ruby 1.x syntax)"
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
    @State private var engineSettings: EngineMkxpSettings
    @State private var defaults: GameConfigDefaults
    /// Auto-detected Ruby version raw value (18/19/30/31), read
    /// from `metadata.rubyVersion`. Populated when the sheet
    /// opens, used to dress the "Auto-detect" picker row with the
    /// version the detector picked, so users can see what
    /// Auto-detect would route to without flipping the override.
    @State private var autoDetectedVersion: Int?
    /// Cached modern-Ruby classification from
    /// `metadata.modernRubyScriptsDetected`, populated when the sheet
    /// opens or after Reset to Defaults. Used to dress the
    /// "Auto-detect" row of the compatibility picker.
    @State private var autoDetectedModernScripts: Bool?

    private let gameDirectory: URL
    private let stateDirectory: URL
    private let initialSettings: GameSettings
    private let initialEngineSettings: EngineMkxpSettings
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

        GameSettings.migrateLegacyEngineSettingsIfNeeded(
            stateDirectory: stateDir,
            gameDirectory: dir
        )

        let s = GameSettings.load(from: stateDir)
        let defs = GameSettings.readGameDefaults(from: dir)
        let engine = EngineMkxpSettings.load(from: stateDir, gameDirectory: dir)

        _settings = State(initialValue: s)
        _engineSettings = State(initialValue: engine)
        _defaults = State(initialValue: defs)
        self.initialSettings = s
        self.initialEngineSettings = engine
        self.isPokemonEssentialsDefault = PokemonEssentialsDetection.detect(
            in: dir, stateDirectory: stateDir
        )
    }

    private var effectiveSmoothScaling: Bool {
        engineSettings.smoothScaling ?? defaults.smoothScaling ?? GameConfigDefaults.engineSmoothScaling
    }
    private var effectiveFixedAspectRatio: Bool {
        engineSettings.fixedAspectRatio ?? defaults.fixedAspectRatio
            ?? GameConfigDefaults.engineFixedAspectRatio
    }
    private var effectiveFrameSkip: Bool {
        engineSettings.frameSkip ?? defaults.frameSkip ?? GameConfigDefaults.engineFrameSkip
    }
    /// Fast-forward is enabled when the user has set a multiplier.
    /// nil ↔ disabled. Toggling the switch ON seeds a sensible
    /// default (4x). The slider then ranges 2-9.
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
        engineSettings.fontScale ?? defaults.fontScale ?? GameConfigDefaults.engineFontScale
    }
    private var effectivePathCache: Bool {
        engineSettings.pathCache ?? defaults.pathCache ?? GameConfigDefaults.enginePathCache
    }
    private var effectiveSolidFonts: Bool {
        engineSettings.solidFonts ?? defaults.solidFonts ?? GameConfigDefaults.engineSolidFonts
    }
    private var effectivePostloadScripts: Bool {
        settings.postloadScripts ?? GameConfigDefaults.enginePostloadScripts
    }
    private var effectiveVerticalAlignment: VerticalAlignment {
        settings.verticalAlignment ?? GameConfigDefaults.engineVerticalAlignment
    }
    private var effectiveRenderScale: RenderScale {
        engineSettings.renderScale ?? defaults.renderScale ?? GameConfigDefaults.engineRenderScale
    }

    private var hasAnyCustomizations: Bool {
        settings.hasCustomizations || engineSettings.hasOverrides(devDefaults: defaults)
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
        // Old metadata may carry 30 from when a native 3.0 binding
        // shipped. The dispatcher folds that onto 3.1 + Legacy.
        case 30, 31: pretty = "Ruby 3.1"
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
    /// `nil` when no relaunch is needed. The parent view binds
    /// that to a conditional render so the pill animates in and out.
    private var restartHint: Hint? {
        guard pauseManager.pausedGame?.id == game.id else { return nil }
        let changed =
            settings.restartRequiredFieldsChanged(from: initialSettings)
            + engineSettings.restartRequiredFieldsChanged(from: initialEngineSettings)
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
                layoutSection
                performanceSection
                engineSection

                if hasAnyCustomizations {
                    Section {
                        Button("Reset to Defaults", role: .destructive) {
                            resetToDefaults()
                        }
                    } footer: {
                        Text("Remove all custom settings and use the game's original values.")
                    }
                }
            }
            // Pin the restart-required pill above the form via a
            // top safe-area inset. The inset gives the pill a
            // z-order above the scrolling rows at no extra cost. We don't
            // try to paint a wide backdrop in the inset's
            // surrounding area because that only produces a
            // visible white/gray panel in light mode (regardless
            // of whether we use material, color, or a blend of
            // both).
            //
            // The pill itself gets a `.regularMaterial` fill
            // clipped to the same rounded shape `HintBanner`
            // already uses internally. It is translucent so form
            // rows scrolling past show through with a blur, yet
            // opaque enough that hint text doesn't visibly
            // collide with row labels underneath. The pill's own
            // brand-tinted layer (`.brand.opacity(0.1)` from
            // `HintBanner`) renders on top of the material, giving
            // the floating pill its brand cast.
            //
            // Slide+blur transition matches `.hintBanner` (same
            // one used by GameInfoView's customization hint). We
            // animate on the boolean (not the excerpt) so adding
            // or removing individual fields updates the text in
            // place without re-running the slide-in transition.
            // Only true appear/disappear cycles trigger movement.
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
            .onChange(of: engineSettings) { save() }
            .task {
                refreshAutoDetection(forceRefresh: false)
            }
        }
        .tint(.brand)
    }

    private var displaySection: some View {
        Section {
            if engineSettings.gameDefaultsUnknown {
                Text(
                    "Empo can't read this game's mkxp.json. Game defaults are unknown."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Group {
                engineFieldRow(.smoothScaling) {
                    SettingsToggle(
                        title: "Smooth scaling",
                        isOn: smoothScalingBinding,
                        description:
                            "Smooth the picture when the game scales up. Turn it off to keep the pixels crisp."
                    )
                }

                engineFieldRow(.fixedAspectRatio) {
                    SettingsToggle(
                        title: "Fixed aspect ratio",
                        isOn: fixedAspectRatioBinding,
                        description:
                            "Preserve the game's proportions instead of stretching to fill the screen."
                    )
                }

                engineFieldRow(.renderScale) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Picker("Render scale", selection: renderScaleBinding) {
                            ForEach(RenderScale.allCases, id: \.self) { scale in
                                Text(scale.label).tag(scale)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        Text(
                            effectiveRenderScale.description
                                + " The game's proportions and on-screen layout do not change. This only makes the picture sharper on high-resolution screens."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                }

                engineFieldRow(.fontScale) {
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
                }

                engineFieldRow(.solidFonts) {
                    SettingsToggle(
                        title: "Solid fonts",
                        isOn: solidFontsBinding,
                        description:
                            "Draw text as solid pixels, with no soft edges. This looks sharper in some games."
                    )
                }
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Control how the game looks on screen.")
        }
    }

    @State private var showLayoutProfilePicker = false

    /// ONE section for everything layout: the profile (controls +
    /// screen placement), the save-as-profile shortcut, and the
    /// portrait position preset the profile can override. Merged so
    /// the override relationship is visible in place.
    private var layoutSection: some View {
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
                onDismiss: { reloadResolvedScreen() },
                content: {
                    LayoutProfilePickerSheet(container: game.container!)
                }
            )
            .onAppear { reloadResolvedScreen() }
        } header: {
            Text("Layout")
        } footer: {
            if profileSetsScreenPortrait || profileSetsScreenLandscape {
                Text(
                    "Profiles live in Settings and work for any game. The profile also sets where the game sits on screen."
                )
            } else {
                Text("Profiles live in Settings and work for any game.")
            }
        }
    }

    /// The resolved screen placement per orientation. The footer
    /// only asks whether a placement exists. It does not care which
    /// profile set it. Cached: Form bodies re-render on every
    /// control interaction, and the resolve reads two files.
    @State private var resolvedScreen: ScreenResolution.Result?

    private func reloadResolvedScreen() {
        guard let container = game.container else { return }
        let store = LayoutProfilesManager.store
        resolvedScreen = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { store.readScreen($0) }
        )
    }

    private var profileSetsScreenPortrait: Bool {
        resolvedScreen?.portrait.placement != nil
    }

    private var profileSetsScreenLandscape: Bool {
        resolvedScreen?.landscape.placement != nil
    }

    private var currentPinLabel: String {
        guard let container = game.container else { return "" }
        switch LayoutProfilesManager.store.loadPin(forGameFolder: container.url).pin {
        case .followChain: return "Automatic"
        case .profile(let name): return name
        case .gameLayout: return "Game layout"
        case .defaultProfile: return "Default profile"
        }
    }

    private var performanceSection: some View {
        Section {
            engineFieldRow(.frameSkip) {
                SettingsToggle(
                    title: "Frame skip",
                    isOn: frameSkipBinding,
                    description:
                        "Skip frames when the game falls behind. The game keeps up better, but motion looks less smooth."
                )
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("Change how the engine handles heavy scenes.")
        }
    }

    private var engineSection: some View {
        Section {
            SettingsToggle(
                title: "Postload scripts",
                isOn: postloadScriptsBinding,
                description:
                    "Run Empo's compatibility scripts after the game loads its own. They fill in common RPG Maker gaps, like missing plugins and the cheat menu, plus fixes for Pokemon Essentials graphics, input, online play, and tilemaps."
            )

            engineFieldRow(.pathCache) {
                SettingsToggle(
                    title: "Path cache",
                    isOn: pathCacheBinding,
                    description:
                        "Keep a lowercase index of every game file so lookups are faster. Turn it off if the game can't find its images or sounds."
                )
            }

            SettingsToggle(
                title: "In-game keyboard",
                isOn: useInGameKeyboardBinding,
                description:
                    "Use the game's own keyboard for names instead of the iOS one. Turn it on for Pokemon Essentials games with custom keys."
            )

            SettingsToggle(
                title: "Touch acts as mouse",
                isOn: touchMouseBinding,
                description:
                    "Send taps and drags on the game screen to the game as mouse input."
            )

            SettingsToggle(
                title: "JoiPlay compatibility",
                isOn: joiplayCompatBinding,
                description:
                    "Tell the game it's running on JoiPlay ($joiplay). Some games then switch to their mobile version. Others were patched for JoiPlay's older engine and will misbehave here. Worth trying if a game breaks on something its PC version handles fine."
            )

            SettingsToggle(
                title: "Network access",
                isOn: networkEnabledBinding,
                description:
                    "Let this game use the internet for update checks, downloads, and online features. The game chooses which servers it contacts, and some games do not encrypt what they send. When off, the game acts as if the device is in airplane mode."
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker("Ruby version", selection: rubyVersionBinding) {
                    Text(autoDetectLabel).tag(RubyVersionPick.auto)
                    Text(RubyVersionPick.v18.displayLabel).tag(RubyVersionPick.v18)
                    Text(RubyVersionPick.v19.displayLabel).tag(RubyVersionPick.v19)
                    Text(RubyVersionPick.v31.displayLabel).tag(RubyVersionPick.v31)
                }
                .pickerStyle(.navigationLink)

                Text(
                    "Auto-detect reads the game's scripts and picks the correct Ruby version. Change it only if the game shows a script error or runs wrongly."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)

            if effectiveRubyVersionInt >= 30 {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Picker("Compatibility mode", selection: compatibilityBinding) {
                        Text(autoDetectCompatLabel).tag(CompatibilityPick.auto)
                        Text(CompatibilityPick.modern.displayLabel).tag(CompatibilityPick.modern)
                        Text(CompatibilityPick.legacy.displayLabel).tag(CompatibilityPick.legacy)
                    }
                    .pickerStyle(.navigationLink)

                    Text(
                        "Set whether the engine rewrites old Ruby 1.x code into a form Ruby 3 accepts. Ruby 1.8 and 1.9 read the old code directly, so this option only shows for Ruby 3. Switch to Legacy if a Pokemon Essentials game shows an error such as `private method called for Kernel:Module`."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Engine options that change how games load and how well they run.")
        }
    }

    private var gameplaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsToggle(
                    title: "Fast forward",
                    isOn: fastForwardEnabledBinding,
                    description:
                        "Add a Fast forward button to the in-game menu. While it is on, the game runs at the speed below."
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
            // Cheats live in App Settings (Experimental section).
            // The per-game toggle was orthogonal stored-but-unused
            // state. See the commit message and TODO.md "P0 #3".
            Text("Options that change how you play the game.")
        }
    }

    private var smoothScalingBinding: Binding<Bool> {
        Binding(
            get: { effectiveSmoothScaling },
            set: { engineSettings.smoothScaling = $0 }
        )
    }

    private var fixedAspectRatioBinding: Binding<Bool> {
        Binding(
            get: { effectiveFixedAspectRatio },
            set: { engineSettings.fixedAspectRatio = $0 }
        )
    }

    private var frameSkipBinding: Binding<Bool> {
        Binding(
            get: { effectiveFrameSkip },
            set: { engineSettings.frameSkip = $0 }
        )
    }

    private var fastForwardEnabledBinding: Binding<Bool> {
        Binding(
            get: { fastForwardEnabled },
            set: { newValue in
                // Enabling: seed default 4x if no value yet (or if
                // a stale 1x lingers from the old single-slider UI).
                // Disabling: clear the multiplier so the toggle and
                // the toolbar sheet both treat the game as
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

    /// Slider binding. Only meaningful when fast-forward is enabled.
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
            set: { engineSettings.fontScale = $0 }
        )
    }

    private var pathCacheBinding: Binding<Bool> {
        Binding(
            get: { effectivePathCache },
            set: { engineSettings.pathCache = $0 }
        )
    }

    private var solidFontsBinding: Binding<Bool> {
        Binding(
            get: { effectiveSolidFonts },
            set: { engineSettings.solidFonts = $0 }
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

    private var touchMouseBinding: Binding<Bool> {
        Binding(
            get: { settings.touchMouse ?? true },
            set: { settings.touchMouse = $0 }
        )
    }

    private var networkEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.networkEnabled ?? true },
            set: { settings.networkEnabled = $0 }
        )
    }

    private var joiplayCompatBinding: Binding<Bool> {
        Binding(
            get: { settings.joiplayCompat ?? false },
            set: { settings.joiplayCompat = $0 }
        )
    }

    /// Picker backing for `GameSettings.rubyVersionOverride`:
    /// nil  -> .auto (use detection from metadata.rubyVersion),
    /// 18/19/30/31 -> force that Ruby interpreter version.
    private var rubyVersionBinding: Binding<RubyVersionPick> {
        Binding(
            get: { RubyVersionPick.from(settings.rubyVersionOverride) },
            set: { pick in
                settings.rubyVersionOverride = pick.rubyVersionInt
            }
        )
    }

    /// Effective Ruby major+minor (1.8 -> 18 ... 3.1 -> 31) the
    /// engine will boot for this game. Mirrors `AppState.selectGame`'s
    /// resolution: explicit override wins, else auto-detected
    /// metadata, else 0 (unknown / unset). Used to gate the
    /// compatibility-mode picker since the syntax-transform flag is
    /// a no-op on Ruby < 3.0 (those interpreters parse legacy syntax
    /// natively).
    private var effectiveRubyVersionInt: Int {
        if let override = settings.rubyVersionOverride { return override }
        if let detected = autoDetectedVersion { return detected }
        return 0
    }

    /// Label for the Auto-detect row in the compatibility picker.
    /// Mirrors `autoDetectLabel` for the Ruby-version picker:
    /// dresses the row with the value the script scanner would
    /// resolve to right now for this game, so the user can pick
    /// "Auto-detect" with confidence. Shows plain "Auto-detect"
    /// while the scan is still running in the background.
    private var autoDetectCompatLabel: String {
        guard let modern = autoDetectedModernScripts else { return "Auto-detect" }
        let resolved =
            modern
            ? CompatibilityPick.modern.displayLabel
            : CompatibilityPick.legacy.displayLabel
        return "Auto-detect (\(resolved))"
    }

    /// Picker backing for `GameSettings.useModernRuby`:
    /// nil   -> .auto (script scanner picks based on grammar),
    /// true  -> .modern (engine skips the 1.x compat rewrite),
    /// false -> .legacy (engine applies the 1.x compat rewrite).
    private var compatibilityBinding: Binding<CompatibilityPick> {
        Binding(
            get: { CompatibilityPick.from(settings.useModernRuby) },
            set: { pick in
                settings.useModernRuby = pick.useModernRubyValue
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
            set: { engineSettings.renderScale = $0 }
        )
    }

    private func resetEngineField(_ field: MkxpEngineField) {
        withAnimation {
            engineSettings.resetField(
                field,
                gameDirectory: gameDirectory,
                stateDirectory: stateDirectory
            )
        }
    }

    @ViewBuilder
    private func engineFieldRow<Content: View>(
        _ field: MkxpEngineField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let provenance = engineSettings.provenance(for: field)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            content()
            // Annotate only the rows the user overrode. Rows that
            // still follow the game's own mkxp.json stay unmarked -
            // that is the normal state and needs no callout.
            if provenance == .yours {
                Text("Changed by you")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if provenance == .yours {
                Button("Use game value", role: .destructive) {
                    resetEngineField(field)
                }
            }
        }
    }

    private func save() {
        settings.save(to: stateDirectory)
        engineSettings.save(to: stateDirectory, gameDirectory: gameDirectory)
    }

    private func resetToDefaults() {
        withAnimation {
            settings = GameSettings()
            defaults = GameSettings.readGameDefaults(from: gameDirectory)
            engineSettings.resetToDefaults(
                gameDirectory: gameDirectory,
                stateDirectory: stateDirectory
            )
        }
        Task {
            refreshAutoDetection(forceRefresh: true)
        }
    }

    /// Loads or re-runs the Ruby-version and compatibility-mode
    /// sniffers so the Auto-detect picker rows show what the
    /// engine would route to. Reads cached metadata on sheet open.
    /// `forceRefresh` re-sniffs the game folder and rewrites
    /// `metadata.json` (Reset to Defaults).
    private func refreshAutoDetection(forceRefresh: Bool) {
        guard let container = game.container else { return }
        var metadata = GameMetadata.load(from: container)
        metadata.refreshDetectedRubyVersion(in: container, forceRefresh: forceRefresh)
        metadata.refreshDetectedModernRubyScripts(in: container, forceRefresh: forceRefresh)
        autoDetectedVersion = metadata.rubyVersion
        autoDetectedModernScripts = metadata.modernRubyScriptsDetected
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

            let gameY: CGFloat =
                switch alignment {
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
