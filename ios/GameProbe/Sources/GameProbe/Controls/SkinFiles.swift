import Foundation

/// Which art file of a profile skin.
public enum SkinOrientation: String, Sendable {
    case portrait
    case landscape
}

/// `Profiles/<Name>/skin.json`. Empo-private and profile-only, like
/// `screen.json`: never read from game folders and not part of the
/// controls v1 spec.
public struct SkinSettings: Equatable, Sendable {
    /// Draw the controls over the art. Off by default: the painted
    /// buttons are the visible buttons, and the controls only take
    /// touches.
    public var showButtonOutlines: Bool

    public init(showButtonOutlines: Bool) {
        self.showButtonOutlines = showButtonOutlines
    }

    public static let defaults = SkinSettings(showButtonOutlines: false)
}

/// Profile skin files: `skin-portrait.*` and `skin-landscape.*` art
/// plus `skin.json`, all inside the profile folder so rename,
/// duplicate, and delete carry them. Finding codes use the `K`
/// namespace.
public enum SkinFiles {
    public static let settingsFileName = "skin.json"

    /// Accepted art extensions, in precedence order when a folder
    /// holds several for one orientation.
    public static let extensions = ["png", "jpg", "jpeg"]

    public enum InstallError: Error, Equatable {
        case unsupportedExtension(String)
    }

    /// The art for one orientation. Names match case-insensitively,
    /// so a hand-copied `Skin-Portrait.JPG` still counts.
    public static func artLookup(
        profileFolder: URL, orientation: SkinOrientation
    ) -> (url: URL?, findings: [String]) {
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: profileFolder.path)) ?? []
        let matches = entries.compactMap { name -> (name: String, rank: Int)? in
            let lower = name.lowercased()
            for (rank, ext) in extensions.enumerated()
            where lower == baseName(orientation) + "." + ext {
                return (name, rank)
            }
            return nil
        }
        guard let best = matches.min(by: { $0.rank < $1.rank }) else { return (nil, []) }
        var findings: [String] = []
        if matches.count > 1 {
            findings.append(
                "W-K1: several \(orientation.rawValue) art files, using \(best.name)")
        }
        return (profileFolder.appendingPathComponent(best.name), findings)
    }

    /// A missing file is the defaults with no findings. Invalid
    /// content is the defaults plus findings, for the caller to log.
    public static func readSettings(
        profileFolder: URL
    ) -> (settings: SkinSettings, findings: [String]) {
        let url = profileFolder.appendingPathComponent(settingsFileName)
        guard let data = try? Data(contentsOf: url) else { return (.defaults, []) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (.defaults, ["K001: skin.json is not a JSON object"])
        }
        guard object["showButtonOutlines"] != nil else { return (.defaults, []) }
        // JSONDecoder is strict about Bool on every platform: 0, 1 and
        // strings are type mismatches. JSONSerialization would bridge
        // them all to NSNumber, and CoreFoundation's type check is not
        // available on Linux, where GameProbe's tests also run.
        guard let raw = try? JSONDecoder().decode(RawSettings.self, from: data),
            let value = raw.showButtonOutlines
        else {
            return (.defaults, ["K002: showButtonOutlines is not true or false"])
        }
        return (SkinSettings(showButtonOutlines: value), [])
    }

    private struct RawSettings: Decodable {
        var showButtonOutlines: Bool?
    }

    public static func writeSettings(_ settings: SkinSettings, profileFolder: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["showButtonOutlines": settings.showButtonOutlines],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: profileFolder.appendingPathComponent(settingsFileName), options: .atomic)
    }

    /// Writes the art under its canonical lowercase name, then drops
    /// the orientation's other extensions. The bytes land in a temp
    /// file first, so a failed write leaves the old art in place.
    @discardableResult
    public static func installArt(
        _ data: Data, fileExtension: String, orientation: SkinOrientation,
        profileFolder: URL
    ) throws -> URL {
        let ext = fileExtension.lowercased()
        guard extensions.contains(ext) else { throw InstallError.unsupportedExtension(ext) }
        let fm = FileManager.default
        let destination = profileFolder.appendingPathComponent(baseName(orientation) + "." + ext)
        let temp = profileFolder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            try removeArt(orientation: orientation, profileFolder: profileFolder)
            try fm.moveItem(at: temp, to: destination)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return destination
    }

    /// Copies the art and `skin.json` (nothing else) into another
    /// profile folder, for a profile minted from an edit on this one.
    public static func copySkin(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        var names: [String] = []
        for orientation in [SkinOrientation.portrait, .landscape] {
            if let url = artLookup(profileFolder: source, orientation: orientation).url {
                names.append(url.lastPathComponent)
            }
        }
        if fm.fileExists(atPath: source.appendingPathComponent(settingsFileName).path) {
            names.append(settingsFileName)
        }
        for name in names {
            let destination = target.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source.appendingPathComponent(name), to: destination)
        }
    }

    public static func removeArt(orientation: SkinOrientation, profileFolder: URL) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: profileFolder.path)) ?? []
        let prefix = baseName(orientation) + "."
        for name in entries {
            let lower = name.lowercased()
            guard lower.hasPrefix(prefix), extensions.contains(String(lower.dropFirst(prefix.count)))
            else { continue }
            try fm.removeItem(at: profileFolder.appendingPathComponent(name))
        }
    }

    private static func baseName(_ orientation: SkinOrientation) -> String {
        "skin-" + orientation.rawValue
    }
}
