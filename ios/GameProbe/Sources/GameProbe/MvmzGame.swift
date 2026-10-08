import Foundation

/// Tells whether the RPG Maker MV and MZ core can run a folder.
///
/// The core opens the folder's `index.html`, and both editions keep
/// their database in `data/`. A desktop MV release keeps the two in
/// `www/`, so there the `www` folder is the game.
public enum MvmzGame {

    public static func isGameRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("index.html").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("data/System.json").path)
    }

    /// MZ ships `rmmz_core.js`, and MV ships `rpg_core.js`.
    public static func isMZ(at url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("js/rmmz_core.js").path)
    }

    /// The title the game shows in its window, from `data/System.json`.
    public static func title(at url: URL) -> String? {
        guard
            let title = (system(at: url)?["gameTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { return nil }
        return title
    }

    /// The picture behind the title screen. An encrypted game has no
    /// PNG to show.
    public static func titlePicture(at url: URL, fileManager: FileManager = .default) -> URL? {
        guard let name = system(at: url)?["title1Name"] as? String, !name.isEmpty, !name.contains("/")
        else { return nil }
        let picture = url.appendingPathComponent("img/titles1/\(name).png")
        return fileManager.fileExists(atPath: picture.path) ? picture : nil
    }

    private static func system(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("data/System.json")) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
