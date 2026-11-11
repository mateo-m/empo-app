// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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

    /// nil follows the sound set of the app settings.
    @Setting<GameMidiSoundSet?, RestartFlag> var midiSoundSet: GameMidiSoundSet?

    static func displayLabel(forKey key: String) -> String {
        switch key {
        case "useInGameKeyboard": return String(localized: "In-game keyboard")
        case "postloadScripts": return String(localized: "Fix-up scripts")
        case "useModernRuby": return String(localized: "Ruby compatibility mode")
        case "rubyVersionOverride": return String(localized: "Ruby version")
        case "joiplayCompat": return String(localized: "JoiPlay compatibility")
        case "networkEnabled": return String(localized: "Network access")
        case "midiSoundSet": return String(localized: "MIDI sound set")
        default:
            assertionFailure("Missing displayLabel mapping for MkxpSettings.\(key)")
            return key
        }
    }

    var postloadScriptsEnabled: Bool { postloadScripts ?? true }
    var joiplayCompatEnabled: Bool { joiplayCompat ?? false }
    var networkAccessEnabled: Bool { networkEnabled ?? true }

    /// The sound font for the engine. An empty path is the engine's built-in
    /// set, and nil leaves the sound font to the game's `mkxp.json`.
    func midiSoundFont(for container: GameContainer, gameSoundFont: URL?) -> String? {
        if midiSoundSet == .builtIn {
            return ""
        }
        if midiSoundSet == .imported, let file = MidiSoundSet.game(container).current {
            return file.path
        }
        return gameSoundFont?.path ?? MidiSoundSet.app.current?.path
    }
}

/// The sound font that a game ships. Default plays it, not the app's set.
enum MkxpGameSoundFont {
    static func url(in container: GameContainer) -> URL? {
        ManagedMkxpConfig.namedSoundFont(in: container.gameURL)
            ?? shipped(in: container).files.first.map { container.gameURL.appendingPathComponent($0) }
    }

    /// A walk of a large game folder takes a tenth of a second or more. The Files app and Finder
    /// can change the folder while Empo is closed. A new, removed, or renamed file changes the
    /// date of its folder, so the stored list is good while each folder keeps its date.
    private static func shipped(in container: GameContainer) -> ShippedSoundFonts {
        let url = container.metadataURL.appendingPathComponent("mkxp-sound-fonts.json")
        if let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(ShippedSoundFonts.self, from: data),
            stored.folders.allSatisfy({ path, date in
                ShippedSoundFonts.modificationDate(of: container.gameURL.appendingPathComponent(path)) == date
            })
        {
            return stored
        }
        let found = ManagedMkxpConfig.shippedSoundFonts(in: container.gameURL)
        container.ensureMetadataDirectory()
        if let data = try? JSONEncoder().encode(found) {
            try? data.write(to: url, options: .atomic)
        }
        return found
    }
}

enum GameMidiSoundSet: String, Codable {
    case builtIn
    /// The file in the game's own `EmpoState/SoundFonts/`.
    case imported
}

struct MkxpLaunchedSettings: CoreLaunchedSettings {
    let settings: MkxpSettings
    let engine: MkxpEngineSettings
    let midiSoundFont: String?
    let midiSoundFontFile: Int?

    init(container: GameContainer) {
        settings = MkxpSettings.load(from: container.empoStateURL)
        engine = MkxpEngineSettings.load(from: container.empoStateURL)
        midiSoundFont = settings.midiSoundFont(
            for: container, gameSoundFont: MkxpGameSoundFont.url(in: container))
        midiSoundFontFile = Self.fileNumber(of: midiSoundFont)
    }

    /// An import of a file with the same name keeps the path, but the
    /// new file has a different file number.
    static func fileNumber(of path: String?) -> Int? {
        path.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.systemFileNumber] as? Int }
    }

    func restartRequiredChanges(to current: any CoreSettings) -> [String] {
        guard let current = current as? MkxpSettingsState else { return [] }
        var changed = current.settings.restartRequiredFieldsChanged(from: settings)
        // An import replaces the file and keeps the setting the same.
        let soundSetLabel = MkxpSettings.displayLabel(forKey: "midiSoundSet")
        if current.midiSoundFont != midiSoundFont
            || Self.fileNumber(of: current.midiSoundFont) != midiSoundFontFile,
            !changed.contains(soundSetLabel)
        {
            changed.append(soundSetLabel)
        }
        return changed + current.engine.restartRequiredFieldsChanged(from: engine)
    }
}

@MainActor @Observable
final class MkxpSettingsState: CoreSettings {
    var settings: MkxpSettings
    var engine: MkxpEngineSettings
    private(set) var gameDefaults: MkxpEngineSettings
    /// What the script scan found. It labels the Auto-detect rows.
    private(set) var profile: MkxpProfile
    let isPokemonEssentials: Bool
    /// The file in the game's own sound set folder. The picker sets it after an import.
    var gameMidiSoundSet: URL?
    let gameSoundFont: URL?

    @ObservationIgnored let container: GameContainer

    init(container: GameContainer) {
        self.container = container
        let settings = MkxpSettings.load(from: container.empoStateURL)
        self.settings = settings
        self.engine = MkxpEngineSettings.load(from: container.empoStateURL)
        self.gameDefaults = MkxpEngineSettings.gameDefaults(in: container.gameURL)
        self.profile = MkxpProfile.load(for: container)
        self.isPokemonEssentials = PokemonEssentialsDetection.detect(
            in: container.gameURL, stateDirectory: container.empoStateURL)
        self.gameMidiSoundSet = MidiSoundSet.game(container).current
        self.gameSoundFont = MkxpGameSoundFont.url(in: container)
    }

    /// Default plays the app's set, which another window can change.
    var midiSoundFont: String? {
        _ = MidiSoundSetCopies.shared.revision(of: .app)
        return settings.midiSoundFont(for: container, gameSoundFont: gameSoundFont)
    }

    var hasCustomizations: Bool { settings.hasCustomizations || engine.hasOverrides }

    var isBusy: Bool { MidiSoundSetCopies.shared.isCopying(into: .game(container)) }

    /// The sound set picker and `reset()` write `midiSoundSet` themselves.
    /// An import can end after this state loaded, so this copy of it is old.
    func save() {
        var saved = settings
        saved.midiSoundSet = MkxpSettings.load(from: container.empoStateURL).midiSoundSet
        saved.save(to: container.empoStateURL)
        engine.save(to: container.empoStateURL)
    }

    func reset() {
        try? MidiSoundSet.game(container).removeImported()
        MidiSoundSetCopies.shared.removed(.game(container))
        gameMidiSoundSet = nil
        settings = MkxpSettings()
        settings.save(to: container.empoStateURL)
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
        settings.rubyVersionOverride ?? profile.ruby.code
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
        case .auto: return String(localized: "Auto-detect")
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
        case .auto: return String(localized: "Auto-detect")
        case .modern: return String(localized: "Modern (newer Ruby)")
        case .legacy: return String(localized: "Legacy (older Ruby)")
        }
    }
}

struct MkxpEngineSection: View {
    let model: GameSettingsModel
    @Bindable var state: MkxpSettingsState

    var body: some View {
        Section {
            SettingsToggle(
                title: "Fix-up scripts",
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
                        "Find game files faster. Turn it off if the game can't find its images or sounds."
                )
            }

            SettingsToggle(
                title: "In-game keyboard",
                isOn: Binding(
                    get: { state.settings.useInGameKeyboard ?? state.isPokemonEssentials },
                    set: { state.settings.useInGameKeyboard = $0 }
                ),
                description:
                    "Pick the letters of a name on the game's own keyboard instead of typing them. Turn it on for Pokemon Essentials games with custom keys."
            )

            #if os(iOS)
            TouchMouseToggle(model: model)
            #endif

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
                    "Let this game use the internet for updates and online features. Some games send data without protection. When it's off, the game can't go online."
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
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif

                SettingsDescription(
                    Text(
                        "Auto-detect reads the game's scripts and picks the correct Ruby version. Change it only if the game shows a script error or runs wrongly."
                    )
                )
            }
            .padding(.vertical, Spacing.xxs)

            // Ruby 1.x parses the old syntax itself, so the rewrite has
            // nothing to do there.
            if state.effectiveRubyVersion >= 30 {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Picker(
                        "Ruby compatibility mode",
                        selection: Binding(
                            get: { CompatibilityPick.from(state.settings.useModernRuby) },
                            set: { state.settings.useModernRuby = $0.useModernRubyValue }
                        )
                    ) {
                        Text(autoDetectCompatLabel).tag(CompatibilityPick.auto)
                        Text(CompatibilityPick.modern.displayLabel).tag(CompatibilityPick.modern)
                        Text(CompatibilityPick.legacy.displayLabel).tag(CompatibilityPick.legacy)
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif

                    SettingsDescription(
                        Text(
                            "Legacy rewrites old Ruby code so newer Ruby can run it. Switch to Legacy if a Pokemon Essentials game crashes with a \"private method\" error."
                        )
                    )
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
        let pick = RubyVersionPick.from(state.profile.ruby.code)
        guard pick != .auto else { return String(localized: "Auto-detect") }
        return String(
            localized: "Auto-detect (\(pick.displayLabel))",
            comment: "Picker option. The placeholder is the choice Empo detected for this game.")
    }

    private var autoDetectCompatLabel: String {
        let resolved: CompatibilityPick = state.profile.ruby.modernScripts ? .modern : .legacy
        return String(
            localized: "Auto-detect (\(resolved.displayLabel))",
            comment: "Picker option. The placeholder is the choice Empo detected for this game.")
    }
}
