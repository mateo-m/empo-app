import Foundation
import GameProbe
import SwiftUI

/// The RPG Maker XP, VX and VX Ace core (mkxp-z).
struct MkxpCore: GameCore {
    let framework = "MkxpCore"
    let symbolPrefix = "mkxp_"

    /// Import refuses a game the mask does not cover, so the name and the
    /// line follow the mask. check-mkxp-framework.sh allows 3, which is
    /// RGSS1 and RGSS2, and 7, which adds RGSS3. A build without the core
    /// has 0, and its refusal names the full core.
    var displayName: String {
        rgssVersionMask == 3 ? "RPG Maker XP and VX core" : "RPG Maker XP, VX and VX Ace core"
    }

    var gamesLine: String {
        rgssVersionMask == 7
            ? "Runs RPG Maker XP, VX and VX Ace games"
            : "Runs RPG Maker XP and VX games"
    }

    /// The core loads a cheat menu script and copies the bridge flag into
    /// `$CHEATS` on every update.
    var supportsCheats: Bool { true }

    /// Which RGSS versions the core runs, as the bitmask that
    /// tools/mkxp-core/build-framework-ios.sh writes. It depends on the
    /// Ruby versions the core carries: Ruby 1.8 alone runs RGSS1 and
    /// RGSS2, and Ruby 3 with the syntax rewrite runs all three. Zero
    /// when this build has no RPG Maker core.
    var rgssVersionMask: Int {
        bundle?.object(forInfoDictionaryKey: "EmpoCoreRGSSVersionMask") as? Int ?? 0
    }

    // MARK: - Import

    func isGameRoot(_ url: URL, fileManager: FileManager) -> Bool {
        guard let items = try? fileManager.contentsOfDirectory(atPath: url.path) else { return false }
        if items.contains(where: { Self.rgssVersion(fromArchive: $0) != nil }) { return true }
        if items.contains(where: { $0.lowercased() == "mkxp.json" }), Self.customScriptPath(url) != nil {
            return true
        }
        return items.contains {
            $0.lowercased().hasSuffix(".ini") && Self.iniScripts(url.appendingPathComponent($0)) != nil
        }
    }

    /// An RGSS archive holds the whole game, so the probe marks its folder
    /// instead of extracting it.
    func archiveEntryUse(_ entry: ArchiveEntry) -> ArchiveEntryUse {
        let name = entry.lowercaseName
        if Self.rgssVersion(fromArchive: name) != nil { return .markRoot }
        if name.hasSuffix(".ini") || name == "mkxp.json" { return .extract }
        if entry.isIn("data"), name.hasPrefix("scripts."),
            name.hasSuffix(".rxdata") || name.hasSuffix(".rvdata") || name.hasSuffix(".rvdata2")
        {
            return .extract
        }
        if entry.isIn("graphics", "titles"), entry.isPicture { return .extract }
        return .skip
    }

    func validateMarkedRoot(marker: String) throws {
        if let version = Self.rgssVersion(fromArchive: marker) {
            try checkSupport(version)
        }
    }

    func validateGameRoot(_ root: URL, fetch: (String) throws -> Void) throws {
        typealias ImportError = GameImportValidator.ImportError
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            throw ImportError.notAGame
        }

        // The scripts of a game with an RGSS archive are inside the
        // archive, and only the version can be checked without a key.
        if let version = items.compactMap(Self.rgssVersion(fromArchive:)).min(by: {
            $0.rawValue < $1.rawValue
        }) {
            try checkSupport(version)
            return
        }

        var scriptsPath: String?
        var version: RGSSVersion?
        for item in items where item.lowercased().hasSuffix(".ini") {
            if let (iniVersion, path) = Self.iniScripts(root.appendingPathComponent(item)) {
                version = iniVersion
                scriptsPath = path
                break
            }
        }

        // Without a customScript and without a usable .ini, the engine
        // does not know where the scripts are and fails at launch.
        var customScript: String?
        if items.contains(where: { $0.lowercased() == "mkxp.json" }) {
            customScript = Self.customScriptPath(root)
            if scriptsPath == nil, customScript == nil { throw ImportError.notAGame }
            if scriptsPath == nil { version = Self.rgssVersionFromMkxpJson(root) }
        }

        if let version { try checkSupport(version) }

        // Game.ini uses Windows paths.
        if let scriptsPath = scriptsPath?.replacingOccurrences(of: "\\", with: "/") {
            try fetch(scriptsPath)
            try Self.checkScriptsFile(at: root, path: scriptsPath)
            return
        }
        if let customScript = customScript?.replacingOccurrences(of: "\\", with: "/") {
            try fetch(customScript)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(customScript).path)
            else { throw ImportError.missingScripts(customScript) }
            return
        }
        throw ImportError.notAGame
    }

    func title(at root: URL) -> String? {
        GameINI.gameTitle(at: root)
    }

    func titlePicture(at root: URL) -> URL? {
        GameCores.firstTitlesPicture(in: root)
    }

    var joiPlayTypes: Set<String> { ["rpgmxp", "rpgmvx", "rpgmvxace", "mkxp-z"] }
    var joiPlayGames: String? { "RPG Maker XP, VX, VX Ace, and mkxp-z games" }

    /// A replacement keeps the user's settings. A fresh import pins
    /// Modern when the scan finds Ruby 3 scripts, and for a JoiPlay
    /// archive made for mkxp-z, which ships Ruby 3 scripts.
    func didImport(_ container: GameContainer, from source: ImportSource, replacing: Bool) {
        let profile = MkxpProfile.load(for: container, rescan: true)
        guard !replacing else { return }
        let modern: Bool
        switch source {
        case .folder: modern = profile.modernRubyScripts
        case .archive: modern = false
        case .joiPlay(let type): modern = type == "mkxp-z" || profile.modernRubyScripts
        }
        guard modern else { return }
        let stateDirectory = container.ensureEmpoStateDirectory()
        var settings = MkxpSettings.load(from: stateDirectory)
        settings.useModernRuby = true
        settings.save(to: stateDirectory)
    }

    // MARK: - Launch

    func launch(_ container: GameContainer) {
        let settings = MkxpSettings.load(from: container.empoStateURL)
        let profile = MkxpProfile.load(for: container, rescan: settings.followsScriptScan)
        let ruby = settings.rubyVersionOverride ?? profile.rubyVersion
        let modern = settings.useModernRuby ?? profile.modernRubyScripts
        let inGameKeyboard =
            settings.useInGameKeyboard
            ?? PokemonEssentialsDetection.detect(
                in: container.gameURL, stateDirectory: container.empoStateURL)

        // The core has no native Ruby 3.0 any more. It runs 3.0 games on 3.1.
        set("rubyVersion", ruby == 30 ? "31" : String(ruby))
        set("syntaxTransform", modern ? "modern" : "legacy")
        set("postloadScripts", settings.postloadScriptsEnabled)
        set("inGameKeyboard", inGameKeyboard)
        set("joiplayCompat", settings.joiplayCompatEnabled)
        set("networkEnabled", settings.networkAccessEnabled)
    }

    private func set(_ key: String, _ value: String) {
        gamecore_setSetting(key, value)
    }

    private func set(_ key: String, _ on: Bool) {
        gamecore_setSetting(key, on ? "1" : "0")
    }

    func launchWarning(for container: GameContainer, gameTitle: String) -> LaunchWarning? {
        // Empo has no way to install the RTP yet, so every game that
        // declares one in Game.ini gets the warning.
        guard let requirement = GameRTPRequirement.detect(at: container.gameURL) else { return nil }
        return LaunchWarning(
            title: "This game needs extra RPG Maker files",
            message: """
                "\(gameTitle)" expects shared \(requirement.friendlySummary) \
                assets that don't ship with it. Empo can't add them yet, so \
                the game may not start or may be missing graphics and sound.
                """,
            confirm: "Play anyway")
    }

    // MARK: - Settings and info

    @MainActor func makeSettings(for container: GameContainer) -> (any CoreSettings)? {
        MkxpSettingsState(container: container)
    }

    @MainActor func settingsPage(_ model: GameSettingsModel) -> AnyView {
        AnyView(
            Group {
                GameplaySettingsSection(model: model)
                DisplaySettingsSection(
                    model: model,
                    fields: [.smoothScaling, .fixedAspectRatio, .renderScale, .fontScale, .solidFonts])
                LayoutSettingsSection(model: model)
                PerformanceSettingsSection(model: model)
                if let state = model.coreSettings as? MkxpSettingsState {
                    MkxpEngineSection(model: model, state: state)
                }
            })
    }

    /// "Ruby (bundled)" is the Ruby that the game's own DLL carries.
    /// "Ruby (runtime)" is the Ruby in this core that runs the game.
    func infoRows(for container: GameContainer) async -> [InfoRow] {
        await Task.detached(priority: .utility) {
            let gameURL = container.gameURL
            var rows = [
                InfoRow(
                    label: "RGSS version",
                    value: MkxpRuntimeProbe.rgssVersion(in: gameURL).map { "RGSS\($0)" })
            ]
            if let bundled = MkxpRuntimeProbe.bundledRubyVersion(in: gameURL) {
                rows.append(InfoRow(label: "Ruby (bundled)", value: bundled))
            }
            let code =
                MkxpSettings.load(from: container.empoStateURL).rubyVersionOverride
                ?? MkxpProfile.load(for: container).rubyVersion
            rows.append(
                InfoRow(label: "Ruby (runtime)", value: MkxpRuntimeProbe.coreRubyVersion(forCode: code)))
            return rows
        }.value
    }

    // MARK: - RGSS files

    private enum RGSSVersion: Int {
        case xp = 1
        case vx = 2
        case vxAce = 3
    }

    private func checkSupport(_ version: RGSSVersion) throws {
        let mask = rgssVersionMask
        // The files are still a game when this build has no RPG Maker
        // core. ImportPipeline and GameLibraryView name the missing core.
        guard mask != 0, mask & (1 << (version.rawValue - 1)) == 0 else { return }
        let label: String
        switch version {
        case .xp: label = "RPG Maker XP (RGSS1)"
        case .vx: label = "RPG Maker VX (RGSS2)"
        case .vxAce: label = "RPG Maker VX Ace (RGSS3)"
        }
        throw GameImportValidator.ImportError.unsupportedRuntime(
            "This game requires \(label). Empo does not support it right now.")
    }

    private static func rgssVersion(fromArchive name: String) -> RGSSVersion? {
        let lower = name.lowercased()
        if lower.hasSuffix(".rgssad") { return .xp }
        if lower.hasSuffix(".rgss2a") { return .vx }
        if lower.hasSuffix(".rgss3a") { return .vxAce }
        return nil
    }

    private static func rgssVersionFromMkxpJson(_ root: URL) -> RGSSVersion? {
        (mkxpJson(root)?["rgssVersion"] as? Int).flatMap(RGSSVersion.init(rawValue:))
    }

    private static func customScriptPath(_ root: URL) -> String? {
        guard let script = mkxpJson(root)?["customScript"] as? String, !script.isEmpty else { return nil }
        return script
    }

    private static func mkxpJson(_ root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("mkxp.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The RGSS version and the raw `Scripts=` path of the `[Game]`
    /// section.
    private static func iniScripts(_ iniURL: URL) -> (RGSSVersion, String)? {
        guard let value = GameINI.parseINIValue(in: iniURL, section: "game", key: "scripts") else {
            return nil
        }
        let lower = value.lowercased()
        if lower.hasSuffix(".rvdata2") { return (.vxAce, value) }
        if lower.hasSuffix(".rvdata") { return (.vx, value) }
        return (.xp, value)
    }

    /// A scripts file is a Ruby Marshal dump of an Array: version bytes
    /// 04 08, then the type tag 5B.
    private static func checkScriptsFile(at root: URL, path: String) throws {
        typealias ImportError = GameImportValidator.ImportError
        let fileURL = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.missingScripts(path)
        }
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw ImportError.invalidScripts(path)
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 3), header == Data([0x04, 0x08, 0x5B]) else {
            throw ImportError.invalidScripts(path)
        }
    }
}
