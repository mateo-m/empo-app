import Foundation

/// The always-in and always-out rules of SPEC 3.1 and 3.2.
///
/// The paths here are relative to a game container,
/// `Documents/Games/<folderName>/`, and they use `/` as the
/// separator. The shared data directory and the Rescued Saves
/// buckets are always in whole, so they need no rule of their own.
///
/// Always out wins over always in, marks included. A mark is
/// additive against the classifier, per 3.6, not a way to bring back
/// a log or an artwork file that 3.2 removed.
public enum BackupSetRules {

    /// The marker a restore puts on a displaced copy and on a
    /// replaced tree, per 11 and 3.2.
    ///
    /// The exclusion is not cosmetic. `PortableGameSaves` reads root
    /// `.bak` files as saves and `ConcatenatedSaveRecovery` walks a
    /// trailing `.bak`, so without it every restore would double a
    /// game's save payload on the next run.
    public static let displacedMarker = "empo-displaced"

    /// The container directory that holds the per-game logs, out per
    /// 3.2.
    public static let logsDirectoryName = "Logs"

    /// The container directory that holds the metadata. Only
    /// `metadata.json` is in, per 3.1. The artwork beside it is out,
    /// per 3.2.
    public static let metadataDirectoryName = "Metadata"
    public static let metadataFileName = "metadata.json"

    /// The container directory that holds Empo's own state, in
    /// whole per 3.1. `backup.json` lives here, so the marks ride
    /// with the game to another device.
    public static let stateDirectoryName = "EmpoState"

    /// A directory of fonts, out per 3.2. The game's own
    /// `Game/Fonts/` and the shared `Documents/Fonts/` both carry
    /// this name.
    public static let fontsDirectoryName = "Fonts"

    /// The container directory that holds the imported game files.
    /// The classifier, the runtime watch, and the picker all work
    /// inside it.
    public static let gameDirectoryName = "Game"

    // MARK: - Always out, per 3.2

    /// Whether a container-relative path stays out of both modes.
    public static func isAlwaysOut(containerRelativePath path: String) -> Bool {
        let components = pathComponents(path)
        guard !components.isEmpty else { return true }

        if components.contains(where: carriesDisplacedMarker) { return true }
        if components.contains(where: { $0.caseInsensitiveCompare(fontsDirectoryName) == .orderedSame }) {
            return true
        }
        if components[0].caseInsensitiveCompare(logsDirectoryName) == .orderedSame {
            return true
        }
        // Under `Metadata/`, `metadata.json` is the only member. The
        // artwork, the banner, and the extracted icon are the
        // artwork files of 3.2.
        if components[0].caseInsensitiveCompare(metadataDirectoryName) == .orderedSame {
            return !(components.count == 2
                && components[1].caseInsensitiveCompare(metadataFileName) == .orderedSame)
        }
        return false
    }

    /// Whether one path component carries the displaced marker.
    ///
    /// A restore leaves `<name>.empo-displaced.bak` beside a save
    /// file and `<name>.empo-displaced` beside a replaced tree, and
    /// it numbers both on a repeat. The match is on the marker
    /// inside the component, so every one of those forms is out.
    public static func carriesDisplacedMarker(_ component: String) -> Bool {
        component.lowercased().contains(displacedMarker)
    }

    // MARK: - Always in, per 3.1

    /// Whether a container-relative path is in whatever the mode
    /// says, per 3.1.
    ///
    /// The three library-wide members of 3.1, the layout profiles,
    /// the UserDefaults export, and the Rescued Saves tree, are not
    /// here. They ride the stream that belongs to no game, per 5.3,
    /// and `BackupSetResolver.resolveLibraryStream` collects them.
    public static func isAlwaysIn(containerRelativePath path: String) -> Bool {
        if isAlwaysOut(containerRelativePath: path) { return false }
        let components = pathComponents(path)
        guard let first = components.first else { return false }
        if first.caseInsensitiveCompare(stateDirectoryName) == .orderedSame { return true }
        if first.caseInsensitiveCompare(metadataDirectoryName) == .orderedSame { return true }
        return false
    }

    // MARK: - Marks

    /// Whether a mark covers a path. A mark on a directory covers
    /// everything under it, per 3.6.
    public static func mark(_ mark: String, covers path: String) -> Bool {
        let markComponents = pathComponents(mark)
        let pathComponents = pathComponents(path)
        guard !markComponents.isEmpty, markComponents.count <= pathComponents.count else {
            return false
        }
        for (index, component) in markComponents.enumerated()
        where component.caseInsensitiveCompare(pathComponents[index]) != .orderedSame {
            return false
        }
        return true
    }

    /// Whether any mark in the list covers the path.
    public static func marks(_ marks: [String], cover path: String) -> Bool {
        marks.contains { mark($0, covers: path) }
    }

    // MARK: - Paths

    /// The components of a `/` separated relative path, with the
    /// empty ones dropped.
    public static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
