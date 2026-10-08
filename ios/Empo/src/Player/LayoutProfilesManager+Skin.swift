import GameProbe
import UIKit

/// Profile skin access for the player, the editor, and the lists.
/// Findings go to the profile's log once per distinct message, the
/// same de-dupe `ScreenRegionApplier` uses for `screen.json`.
extension LayoutProfilesManager {
    private static var loggedSkinFindings: Set<String> = []

    static func skinArtURL(profile name: String, orientation: SkinOrientation) -> URL? {
        let lookup = SkinFiles.artLookup(
            profileFolder: store.profileURL(name), orientation: orientation)
        logSkinFindings(lookup.findings, profile: name)
        return lookup.url
    }

    static func skinSettings(profile name: String) -> SkinSettings {
        let read = SkinFiles.readSettings(profileFolder: store.profileURL(name))
        logSkinFindings(read.findings, profile: name)
        return read.settings
    }

    /// The decoded art, or nil when the profile has none for this
    /// orientation or the file does not decode. A file that exists
    /// but does not decode is logged, and the profile then behaves
    /// like a profile without art.
    static func skinArt(
        profile name: String, orientation: SkinOrientation, maxPixel: CGFloat
    ) -> UIImage? {
        guard let url = skinArtURL(profile: name, orientation: orientation) else { return nil }
        guard let image = SkinArtCache.shared.image(at: url, maxPixel: maxPixel) else {
            logSkinFindings(
                ["K003: \(url.lastPathComponent) could not be read as an image"], profile: name)
            return nil
        }
        return image
    }

    private static func logSkinFindings(_ findings: [String], profile name: String) {
        for line in findings {
            let signature = name + "|" + line
            guard !loggedSkinFindings.contains(signature) else { continue }
            loggedSkinFindings.insert(signature)
            store.appendLog(name, file: SkinFiles.settingsFileName, line: line)
        }
    }
}
