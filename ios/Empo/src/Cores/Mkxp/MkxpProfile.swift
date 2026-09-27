import Foundation
import GameProbe
import os

/// What the script scan found for one game, stored at
/// `Metadata/mkxp-profile.json`.
struct MkxpProfile: Codable {
    /// 18, 19, 30 or 31.
    var rubyVersion: Int
    var modernRubyScripts: Bool
    /// `GameScriptProfile.currentSchema` of the scan that wrote this.
    var schema: String

    /// The stored profile. A new scan replaces it when `rescan` is true,
    /// when nothing is stored, or when older rules wrote it.
    static func load(for container: GameContainer, rescan: Bool = false) -> MkxpProfile {
        let url = container.metadataURL.appendingPathComponent("mkxp-profile.json")
        let currentSchema = GameScriptProfile.currentSchema.rawValue
        if !rescan, let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(MkxpProfile.self, from: data),
            stored.schema == currentSchema
        {
            return stored
        }
        let result = GameScriptProfile.analyze(gameDirectory: container.gameURL)
        let profile = MkxpProfile(
            rubyVersion: result.rubyVersion,
            modernRubyScripts: result.modernRubyScripts,
            schema: currentSchema)
        container.ensureMetadataDirectory()
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: url, options: .atomic)
        }
        return profile
    }
}

/// Version facts for the Runtime section of Game Info.
enum MkxpRuntimeProbe {
    /// The RGSS version (1 = XP, 2 = VX, 3 = VX Ace), which is the
    /// graphics API and not the Ruby version. Pokemon Flux ships RGSS1
    /// graphics with Ruby 3.
    ///
    /// Each signal catches games that the next one misses: `rgssVersion`
    /// in mkxp.json, the extension of `Scripts=` in Game.ini, an RGSS
    /// archive, then the newest family of loose `Data/` files.
    static func rgssVersion(in gameDirectory: URL) -> Int? {
        let fm = FileManager.default

        if let data = try? Data(contentsOf: gameDirectory.appendingPathComponent("mkxp.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let v = json["rgssVersion"] as? Int,
            (1...3).contains(v)
        {
            return v
        }

        let iniURL = gameDirectory.appendingPathComponent("Game.ini")
        if let scripts = GameINI.parseINIValue(in: iniURL, section: "game", key: "scripts") {
            let lower = scripts.lowercased()
            if lower.hasSuffix(".rvdata2") { return 3 }
            if lower.hasSuffix(".rvdata") { return 2 }
            if lower.hasSuffix(".rxdata") { return 1 }
        }

        for dir in [gameDirectory, gameDirectory.appendingPathComponent("Data")] {
            let exts = Set(
                dir.directoryEntries(matchingExtensions: ["rgssad", "rgss2a", "rgss3a"], fm: fm)
                    .map { $0.pathExtension.lowercased() })
            if exts.contains("rgss3a") { return 3 }
            if exts.contains("rgss2a") { return 2 }
            if exts.contains("rgssad") { return 1 }
        }

        let dataExts = Set(
            gameDirectory.appendingPathComponent("Data")
                .directoryEntries(matchingExtensions: ["rxdata", "rvdata", "rvdata2"], fm: fm)
                .map { $0.pathExtension.lowercased() })
        if dataExts.contains("rvdata2") { return 3 }
        if dataExts.contains("rvdata") { return 2 }
        if dataExts.contains("rxdata") { return 1 }
        return nil
    }

    /// The Ruby version of a Ruby library the game ships, such as the
    /// `x64-msvcrt-ruby310.dll` of Pokemon Flux. The scan reads the bytes,
    /// so a renamed library still counts. A real Ruby DLL is 5 to 15 MB,
    /// and the scan skips files over 64 MB.
    static func bundledRubyVersion(in gameDirectory: URL) -> String? {
        let fm = FileManager.default
        for url in gameDirectory.directoryEntries(matchingExtensions: ["dll", "dylib", "so"], fm: fm) {
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
                size <= 64 * 1024 * 1024,
                let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { continue }
            if let v = rubyDescription(in: data, majorMinor: nil) { return v }
        }
        return nil
    }

    /// The version of the Ruby in MkxpCore that runs a game of the given
    /// Ruby code (18, 19, 30 or 31). The binary holds one
    /// `RUBY_DESCRIPTION` for each Ruby it carries.
    static func coreRubyVersion(forCode code: Int) -> String? {
        guard let majorMinor = majorMinor(forCode: code) else { return nil }
        if let cached = cache.withLock({ $0[majorMinor] }) { return cached }
        guard let binary = MkxpCore().binaryURL,
            let data = try? Data(contentsOf: binary, options: .alwaysMapped),
            let version = rubyDescription(in: data, majorMinor: majorMinor)
        else { return nil }
        cache.withLock { $0[majorMinor] = version }
        return version
    }

    /// The core runs a game of code 30 on its Ruby 3.1.
    private static func majorMinor(forCode code: Int) -> String? {
        switch code {
        case 18: return "1.8"
        case 19: return "1.9"
        case 30, 31: return "3.1"
        default: return nil
        }
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    private static let regex = try? NSRegularExpression(pattern: #"ruby (\d+\.\d+\.\d+(?:p\d+)?)"#)

    /// Latin-1 maps each byte to one character, so the binary goes into a
    /// String without loss.
    private static func rubyDescription(in data: Data, majorMinor: String?) -> String? {
        guard let regex else { return nil }
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let version = String(text[range])
            if majorMinor.map({ version.hasPrefix($0 + ".") }) ?? true { return version }
        }
        return nil
    }
}
