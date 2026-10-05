import Foundation
import GameProbe
import SwiftUI

/// The per-game settings only the RPG Maker core reads. They share
/// `game_settings.json` with `GameSettings`.
struct MkxpSettings: GameSettingsGroup {
    /// Runs the engine's fix-up scripts after the game loads.
    @Setting<Bool?, RestartFlag> var postloadScripts: Bool?

    /// nil lets the script scan pick. true runs the scripts as Ruby 3
    /// with no rewrites. false rewrites old forms (`when X:`, hash
    /// rockets, keyword shorthand) before Ruby 3 parses them. Only the
    /// patched Ruby 3.1 parser applies the rewrites.
    @Setting<Bool?, RestartFlag> var useModernRuby: Bool?

    /// nil uses the Ruby version of the script scan. 18, 19, 30 or 31
    /// forces one. An Int, so a value from a newer Empo still decodes.
    @Setting<Int?, RestartFlag> var rubyVersionOverride: Int?

    /// Forces the Pokemon Essentials keyboard scene instead of the iOS
    /// keyboard. `pokemon_input.rb` reads it once at postload time.
    @Setting<Bool?, RestartFlag> var useInGameKeyboard: Bool?

    /// Makes game scripts see `$joiplay = true`. `platform_compat.rb`
    /// sets the global before game scripts load.
    @Setting<Bool?, RestartFlag> var joiplayCompat: Bool?

    /// Off makes every connection fail as with no network, so games take
    /// their own offline paths. The preload layer reads it through
    /// `System.network_enabled?` before game scripts load.
    @Setting<Bool?, RestartFlag> var networkEnabled: Bool?

    static func displayLabel(forKey key: String) -> String {
        switch key {
        case "useInGameKeyboard": return "In-game keyboard"
        case "postloadScripts": return "Postload scripts"
        case "useModernRuby": return "Ruby compatibility mode"
        case "rubyVersionOverride": return "Ruby version"
        case "joiplayCompat": return "JoiPlay compatibility"
        case "networkEnabled": return "Network access"
        default:
            assertionFailure("Missing displayLabel mapping for MkxpSettings.\(key)")
            return key
        }
    }

    var postloadScriptsEnabled: Bool { postloadScripts ?? true }
    var joiplayCompatEnabled: Bool { joiplayCompat ?? false }
    var networkAccessEnabled: Bool { networkEnabled ?? true }
}

@MainActor @Observable
final class MkxpSettingsState: CoreSettings {
    var settings: MkxpSettings
    var engine: MkxpEngineSettings
    private(set) var gameDefaults: MkxpEngineSettings
    /// What the script scan found. It labels the Auto-detect rows.
    private(set) var profile: MkxpProfile
    let isPokemonEssentials: Bool

    @ObservationIgnored private let container: GameContainer
    @ObservationIgnored private let initial: MkxpSettings
    @ObservationIgnored private let initialEngine: MkxpEngineSettings

    init(container: GameContainer) {
        self.container = container
        let settings = MkxpSettings.load(from: container.empoStateURL)
        self.settings = settings
        self.initial = settings
        let engine = MkxpEngineSettings.load(from: container.empoStateURL)
        self.engine = engine
        self.initialEngine = engine
        self.gameDefaults = MkxpEngineSettings.gameDefaults(in: container.gameURL)
        self.profile = MkxpProfile.load(for: container)
        self.isPokemonEssentials = PokemonEssentialsDetection.detect(
            in: container.gameURL, stateDirectory: container.empoStateURL)
    }

    var hasCustomizations: Bool { settings.hasCustomizations || engine.hasOverrides }

    var restartRequiredChanges: [String] {
        settings.restartRequiredFieldsChanged(from: initial)
            + engine.restartRequiredFieldsChanged(from: initialEngine)
    }

    func save() {
        settings.save(to: container.empoStateURL)
        engine.save(to: container.empoStateURL)
    }

    func reset() {
        settings = MkxpSettings()
        profile = MkxpProfile.load(for: container, rescan: true)
        ManagedMkxpConfig.resetAllEngineFields(
            stateDirectory: container.empoStateURL, gameDirectory: container.gameURL)
        engine = MkxpEngineSettings.load(from: container.empoStateURL)
        gameDefaults = MkxpEngineSettings.gameDefaults(in: container.gameURL)
    }

    func resetField(_ field: MkxpEngineField) {
        ManagedMkxpConfig.resetField(
            field, stateDirectory: container.empoStateURL, gameDirectory: container.gameURL)
        engine = MkxpEngineSettings.load(from: container.empoStateURL)
    }

    var effectiveRenderScale: RenderScale {
        engine.renderScale ?? gameDefaults.renderScale ?? MkxpEngineSettings.engineRenderScale
    }
    var effectiveFrameSkip: Bool {
        engine.frameSkip ?? gameDefaults.frameSkip ?? MkxpEngineSettings.engineFrameSkip
    }
    var effectivePathCache: Bool {
        engine.pathCache ?? gameDefaults.pathCache ?? MkxpEngineSettings.enginePathCache
    }
    var effectiveFontScale: Double {
        engine.fontScale ?? gameDefaults.fontScale ?? MkxpEngineSettings.engineFontScale
    }
    var effectiveSolidFonts: Bool {
        engine.solidFonts ?? gameDefaults.solidFonts ?? MkxpEngineSettings.engineSolidFonts
    }

    /// The Ruby version the core boots for this game: 18, 19, 30 or 31.
    var effectiveRubyVersion: Int {
        settings.rubyVersionOverride ?? profile.rubyVersion
    }
}

/// The Ruby version picker. `auto` uses the script scan.
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

    /// Old data can hold 30 from when a native Ruby 3.0 binding shipped.
    /// The core runs it on Ruby 3.1.
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

/// The compatibility mode picker. It has an effect only on Ruby 3.1.
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
        case .modern: return "Modern (newer Ruby)"
        case .legacy: return "Legacy (older Ruby)"
        }
    }
}

struct MkxpEngineSection: View {
    let model: GameSettingsModel
    @Bindable var state: MkxpSettingsState

    var body: some View {
        Section {
            SettingsToggle(
                title: "Postload scripts",
                isOn: Binding(
                    get: { state.settings.postloadScriptsEnabled },
                    set: { state.settings.postloadScripts = $0 }
                ),
                description:
                    "Run Empo's fix-up scripts after the game loads. They add the cheat menu and patch common RPG Maker and Pokemon Essentials problems."
            )

            MkxpEngineRow(state: state, field: .pathCache) {
                SettingsToggle(
                    title: "Path cache",
                    isOn: Binding(
                        get: { state.effectivePathCache },
                        set: { state.engine.pathCache = $0 }
                    ),
                    description:
                        "Keep a lowercase index of every game file so lookups are faster. Turn it off if the game can't find its images or sounds."
                )
            }

            SettingsToggle(
                title: "In-game keyboard",
                isOn: Binding(
                    get: { state.settings.useInGameKeyboard ?? state.isPokemonEssentials },
                    set: { state.settings.useInGameKeyboard = $0 }
                ),
                description:
                    "Use the game's own keyboard for names instead of the iOS one. Turn it on for Pokemon Essentials games with custom keys."
            )

            TouchMouseToggle(model: model)

            SettingsToggle(
                title: "JoiPlay compatibility",
                isOn: Binding(
                    get: { state.settings.joiplayCompatEnabled },
                    set: { state.settings.joiplayCompat = $0 }
                ),
                description:
                    "Tell the game it's running on JoiPlay. Some games switch to their mobile version. Worth trying if a game misbehaves here but works on PC."
            )

            SettingsToggle(
                title: "Network access",
                isOn: Binding(
                    get: { state.settings.networkAccessEnabled },
                    set: { state.settings.networkEnabled = $0 }
                ),
                description:
                    "Let this game use the internet for updates and online features. Some games send data unencrypted. When off, the game sees no network."
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker(
                    "Ruby version",
                    selection: Binding(
                        get: { RubyVersionPick.from(state.settings.rubyVersionOverride) },
                        set: { state.settings.rubyVersionOverride = $0.rubyVersionInt }
                    )
                ) {
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

            // Ruby 1.x parses the old syntax itself, so the rewrite has
            // nothing to do there.
            if state.effectiveRubyVersion >= 30 {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Picker(
                        "Compatibility mode",
                        selection: Binding(
                            get: { CompatibilityPick.from(state.settings.useModernRuby) },
                            set: { state.settings.useModernRuby = $0.useModernRubyValue }
                        )
                    ) {
                        Text(autoDetectCompatLabel).tag(CompatibilityPick.auto)
                        Text(CompatibilityPick.modern.displayLabel).tag(CompatibilityPick.modern)
                        Text(CompatibilityPick.legacy.displayLabel).tag(CompatibilityPick.legacy)
                    }
                    .pickerStyle(.navigationLink)

                    Text(
                        "Legacy rewrites old Ruby code so newer Ruby can run it. Switch to Legacy if a Pokemon Essentials game crashes with a \"private method\" error."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("How games load and how well they run.")
        }
    }

    private var autoDetectLabel: String {
        let pick = RubyVersionPick.from(state.profile.rubyVersion)
        guard pick != .auto else { return "Auto-detect" }
        return "Auto-detect (\(pick.displayLabel))"
    }

    private var autoDetectCompatLabel: String {
        let resolved: CompatibilityPick = state.profile.modernRubyScripts ? .modern : .legacy
        return "Auto-detect (\(resolved.displayLabel))"
    }
}
